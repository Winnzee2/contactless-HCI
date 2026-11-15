#!/usr/bin/env python3
"""Check actual visible app targets with the native scanner and local Bonsai.

Arrange an app and leave its desired label visible, then supply a nearby screen
point and the exact label. This captures the current screen/Accessibility tree;
it never launches apps, opens a camera/microphone, or sends mouse/keyboard input.

Example (use the coordinates and label visible on your own screen):
    python3 scripts/test_cross_app.py --x 300 --y 200 --expected-label Documents \
        --output .build/verification/finder.json

Start the existing local Bonsai service separately before running this check.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import sys
import time
import unicodedata

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "scripts"))
from control.bonsai import BonsaiClient, normalize_candidates
from test_product_offline import NATIVE, NO_NETWORK, json_lines, run_checked


def finite_number(value):
    return not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value)


def report_value(value):
    """Keep failed nonfinite native input readable in standards-compliant JSON."""
    if isinstance(value, float) and not math.isfinite(value):
        return repr(value)
    if isinstance(value, dict):
        return {key: report_value(item) for key, item in value.items()}
    if isinstance(value, list):
        return [report_value(item) for item in value]
    return value


def label_key(value):
    """Ignore case/whitespace, without accepting substrings as expected labels."""
    return " ".join(unicodedata.normalize("NFKC", value).casefold().split())


def rectangle(value, description):
    if not isinstance(value, dict):
        raise RuntimeError(f"{description} must be an object")
    numbers = [value.get(key) for key in ("x", "y", "width", "height")]
    if not all(finite_number(number) for number in numbers) or numbers[2] <= 0 or numbers[3] <= 0:
        raise RuntimeError(f"{description} must have finite coordinates and positive dimensions")
    if not all(math.isfinite(number) for number in (numbers[0] + numbers[2], numbers[1] + numbers[3])):
        raise RuntimeError(f"{description} bounds overflow")
    return tuple(numbers)


def validate_snapshot(events):
    """Require one real diagnostic snapshot with usable native coordinates."""
    if len(events) != 1 or events[0].get("type") != "targets_diagnostic":
        errors = [event.get("message", "Native diagnostic failed") for event in events if event.get("type") == "error"]
        raise RuntimeError("; ".join(errors) if errors else "Expected exactly one native targets_diagnostic event")
    event = events[0]
    if event.get("passed") is False:
        raise RuntimeError("Native target diagnostic failed")
    if type(event.get("mouse_events")) is not int or event["mouse_events"] != 0:
        raise RuntimeError("Native diagnostic did not confirm zero mouse events")
    permissions = [event.get("accessibility"), event.get("screen_recording")]
    if any(type(permission) is not bool for permission in permissions):
        raise RuntimeError("Native diagnostic did not report permission readiness")
    if not any(permissions):
        raise RuntimeError("Accessibility and Screen Recording are unavailable")
    left, top, width, height = rectangle(event.get("region"), "Capture region")
    targets = event.get("targets")
    try:
        normalize_candidates(targets)
    except ValueError as error:
        raise RuntimeError(f"Invalid native targets: {error}") from error
    if not targets:
        raise RuntimeError("No visible targets were captured in this screen region")
    for target in targets:
        x, y, target_width, target_height = rectangle(target, "Native target")
        if not left <= x < left + width or not top <= y < top + height:
            raise RuntimeError(f"Target {target['id']} has a center outside the capture region")
        edges = (x - target_width / 2, y - target_height / 2, x + target_width / 2, y + target_height / 2)
        if not all(math.isfinite(edge) for edge in edges):
            raise RuntimeError(f"Target {target['id']} bounds overflow")
    return event


def expected_target(snapshot, expected_label):
    if not isinstance(expected_label, str) or not label_key(expected_label):
        raise RuntimeError("A nonempty expected visible label is required")
    matches = [target for target in snapshot["targets"] if label_key(target["label"]) == label_key(expected_label)]
    if len(matches) != 1:
        labels = [target["label"] for target in snapshot["targets"]]
        raise RuntimeError(f"Expected exactly one visible label {expected_label!r}; found {len(matches)}. Captured labels: {labels}")
    return matches[0]


def validate_selection(snapshot, expected_label, selection):
    expected = expected_target(snapshot, expected_label)
    selected = next((target for target in snapshot["targets"] if target["id"] == selection.target_id), None)
    if selected is None:
        raise RuntimeError("Bonsai did not select a known visible target ID")
    if selected["id"] != expected["id"]:
        raise RuntimeError(f"Bonsai selected {selected['label']!r}, expected {expected_label!r}")
    x, y, width, height = rectangle(selected, "Selected target")
    bounds = {"x": x - width / 2, "y": y - height / 2, "width": width, "height": height}
    if not bounds["x"] <= x < bounds["x"] + width or not bounds["y"] <= y < bounds["y"] + height:
        raise RuntimeError("Resolved pointer is outside the selected visible target bounds")
    return selected, bounds


class ObservedBonsaiClient(BonsaiClient):
    """Count actual selection HTTP calls, so a local veto cannot count as proof."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.selection_requests = 0

    def _request(self, route, payload=None):
        if route in {"/chat/completions", "/chat"}:
            self.selection_requests += 1
        return super()._request(route, payload)


def verify(*, x, y, expected_label, output, transcript=None,
           bonsai_url="http://127.0.0.1:1234/v1", bonsai_model="bonsai-local"):
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    report = {"started_at": datetime.now(timezone.utc).isoformat(), "passed": False,
              "scope": "one current visible screen region, native target discovery and real local Bonsai selection",
              "expected_label": expected_label, "requested_point": {"x": x, "y": y},
              "transcript": expected_label if transcript is None else transcript,
              "transcript_source": "supplied text; speech recognition is not exercised",
              "pointer_moved": False, "clicks_sent": 0, "keyboard_events_sent": 0,
              "physical_camera_microphone_gestures_tested": False,
              "coordinator_and_actuation_tested": False, "wifi_setting_changed": False,
              "all_app_compatibility_proven": False}
    try:
        if not all(finite_number(value) for value in (x, y)):
            raise RuntimeError("Screen coordinates must be finite numbers")
        if not NATIVE.is_file():
            raise RuntimeError("Build first: bash scripts/build_gesture_app.sh")
        # Validates literal loopback routing before capturing screen content.
        client = ObservedBonsaiClient(bonsai_url, bonsai_model, timeout=30)
        report["bonsai"] = {"url": client.base_url, "model": client.model,
                            "service": "existing local service; not started or stopped by this check"}
        result = run_checked(["/usr/bin/sandbox-exec", "-p", NO_NETWORK, str(NATIVE),
                              "--targets-at", str(x), str(y)], timeout=30)
        report["native_events"] = json_lines(result.stdout)
        snapshot = validate_snapshot(report["native_events"])
        expected_target(snapshot, expected_label)
        report["native_binary_sha256"] = hashlib.sha256(NATIVE.read_bytes()).hexdigest()
        client.check_model()
        selection = client.select_target(report["transcript"], snapshot["targets"])
        report["bonsai"]["selection_requests"] = client.selection_requests
        report["model_selection"] = {"target_id": selection.target_id, "reason": selection.reason}
        if client.selection_requests < 1:
            raise RuntimeError("No real Bonsai selection request was made")
        selected, bounds = validate_selection(snapshot, expected_label, selection)
        report.update({"passed": True, "selected_target": selected, "selected_bounds": bounds,
                       "resolved_pointer": {"x": selected["x"], "y": selected["y"]},
                       "coordinate_source": "native candidate center, never model-generated coordinates"})
        return report
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        report["elapsed_seconds"] = round(time.monotonic() - started, 3)
        output.write_text(json.dumps(report_value(report), ensure_ascii=False, indent=2, allow_nan=False) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--x", required=True, type=float, help="Nearby horizontal screen point")
    parser.add_argument("--y", required=True, type=float, help="Nearby vertical screen point")
    parser.add_argument("--expected-label", "--expect", required=True, help="Exact visible label to verify")
    parser.add_argument("--transcript", "--utterance", help="Text to send to Bonsai; defaults to the expected label")
    parser.add_argument("--bonsai-url", default="http://127.0.0.1:1234/v1")
    parser.add_argument("--bonsai-model", default="bonsai-local")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/verification/cross-app.json")
    args = parser.parse_args()
    try:
        report = verify(**vars(args))
    except Exception as error:
        print(f"Cross-app target check failed: {error}", file=sys.stderr)
        print(f"Report: {args.output.resolve()}", file=sys.stderr)
        return 1
    print(f"Bonsai selected: {report['selected_target']['label']}")
    print(f"Native target center: ({report['resolved_pointer']['x']}, {report['resolved_pointer']['y']})")
    print("Point is inside the captured target bounds. No pointer movement or clicks were sent.")
    print(f"Report: {args.output.resolve()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
