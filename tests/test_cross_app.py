"""The real-screen acceptance harness must not misreport unsafe or absent targets."""

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("cross_app_verifier", ROOT / "scripts/test_cross_app.py")
cross_app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cross_app)
from control.bonsai import SelectedTarget


class TestCrossAppVerifier(unittest.TestCase):
    def setUp(self):
        self.snapshot = {"type": "targets_diagnostic", "mouse_events": 0,
                         "accessibility": True, "screen_recording": True,
                         "region": {"x": 100, "y": 100, "width": 720, "height": 420},
                         "targets": [{"id": "native-7", "label": "Documents", "x": 200,
                                      "y": 180, "width": 120, "height": 24,
                                      "source": "accessibility", "role": "AXButton"}]}

    def test_real_native_bounds_are_preserved_without_actuation(self):
        snapshot = cross_app.validate_snapshot([self.snapshot])
        selected, bounds = cross_app.validate_selection(snapshot, "Documents", SelectedTarget("native-7"))
        self.assertIs(selected, self.snapshot["targets"][0])
        self.assertEqual(bounds, {"x": 140, "y": 168, "width": 120, "height": 24})

    def test_partially_cropped_control_is_valid_when_its_center_is_visible(self):
        self.snapshot["targets"][0].update(x=110, width=100)
        cross_app.validate_snapshot([self.snapshot])
        selected, _ = cross_app.validate_selection(self.snapshot, "Documents", SelectedTarget("native-7"))
        self.assertEqual(selected["x"], 110)

    def test_outside_nonfinite_boolean_and_empty_geometry_is_rejected(self):
        for change in ({"x": 99}, {"x": 820}, {"y": 520}, {"width": 0},
                       {"height": -1}, {"x": float("nan")}, {"y": float("inf")}, {"x": True}):
            snapshot = copy.deepcopy(self.snapshot)
            snapshot["targets"][0].update(change)
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                cross_app.validate_snapshot([snapshot])

    def test_missing_unknown_wrong_and_ambiguous_label_do_not_pass(self):
        with self.assertRaises(RuntimeError):
            cross_app.validate_selection(self.snapshot, "Document", SelectedTarget("native-7"))
        for identifier in (None, "invented"):
            with self.subTest(identifier=identifier), self.assertRaises(RuntimeError):
                cross_app.validate_selection(self.snapshot, "Documents", SelectedTarget(identifier))
        self.snapshot["targets"].append(dict(self.snapshot["targets"][0], id="other", label="Downloads"))
        with self.assertRaises(RuntimeError):
            cross_app.validate_selection(self.snapshot, "Documents", SelectedTarget("other"))
        self.snapshot["targets"][1]["label"] = " DOCUMENTS "
        with self.assertRaisesRegex(RuntimeError, "found 2"):
            cross_app.validate_selection(self.snapshot, "Documents", SelectedTarget("native-7"))

    def test_errors_multiple_events_and_input_activity_do_not_pass(self):
        for events in ([], [self.snapshot, self.snapshot],
                       [{"type": "error", "message": "Permission missing"}],
                       [dict(self.snapshot, mouse_events=1)],
                       [dict(self.snapshot, mouse_events=False)],
                       [dict(self.snapshot, passed=False)],
                       [dict(self.snapshot, targets=[])],
                       [dict(self.snapshot, accessibility=False, screen_recording=False)]):
            with self.subTest(events=events), self.assertRaises(RuntimeError):
                cross_app.validate_snapshot(events)

    def test_either_native_source_can_supply_visible_targets(self):
        cross_app.validate_snapshot([dict(self.snapshot, accessibility=False)])
        cross_app.validate_snapshot([dict(self.snapshot, screen_recording=False)])

    def test_success_requires_model_request_and_contains_only_resolved_coordinates(self):
        calls = []
        def model_request(route, payload=None):
            calls.append((route, payload))
            if route == "/models":
                return {"data": [{"id": "bonsai-local"}]}
            return {"choices": [{"message": {"content": '{"target_id":"0"}'}}]}
        with tempfile.TemporaryDirectory() as directory:
            native = Path(directory) / "native"
            native.write_bytes(b"test native executable")
            output = Path(directory) / "result.json"
            with patch.object(cross_app, "NATIVE", native), \
                 patch.object(cross_app, "run_checked", return_value=SimpleNamespace(stdout=json.dumps(self.snapshot))) as capture, \
                 patch.object(cross_app.BonsaiClient, "_request", side_effect=model_request):
                report = cross_app.verify(x=200, y=180, expected_label="Documents", output=output)
            self.assertTrue(report["passed"])
            self.assertEqual(report["bonsai"]["selection_requests"], 1)
            self.assertEqual(report["resolved_pointer"], {"x": 200, "y": 180})
            self.assertFalse(report["pointer_moved"])
            self.assertFalse(report["coordinator_and_actuation_tested"])
            self.assertFalse(report["all_app_compatibility_proven"])
            self.assertEqual(report["clicks_sent"], 0)
            self.assertNotIn("captured_instruction", report)
            self.assertEqual(capture.call_args.args[0][-3:], ["--targets-at", "200", "180"])
            self.assertEqual([call[0] for call in calls], ["/models", "/chat/completions"])
            model_payload = json.loads(calls[1][1]["messages"][1]["content"])
            self.assertNotIn("x", model_payload["candidates"][0])
            self.assertEqual(json.loads(output.read_text())["selected_bounds"]["x"], 140)

    def test_no_inference_cannot_be_reported_as_a_model_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            native = Path(directory) / "native"
            native.touch()
            output = Path(directory) / "result.json"
            with patch.object(cross_app, "NATIVE", native), \
                 patch.object(cross_app, "run_checked", return_value=SimpleNamespace(stdout=json.dumps(self.snapshot))), \
                 patch.object(cross_app.ObservedBonsaiClient, "check_model", return_value=True), \
                 patch.object(cross_app.ObservedBonsaiClient, "select_target", return_value=SelectedTarget("native-7")):
                with self.assertRaisesRegex(RuntimeError, "No real Bonsai"):
                    cross_app.verify(x=200, y=180, expected_label="Documents", output=output)
            self.assertFalse(json.loads(output.read_text())["passed"])

    def test_invalid_input_replaces_stale_success_with_valid_failure_json(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "result.json"
            output.write_text('{"passed":true}')
            with self.assertRaisesRegex(RuntimeError, "finite numbers"):
                cross_app.verify(x=float("nan"), y=180, expected_label="Documents", output=output)
            report = json.loads(output.read_text(), parse_constant=lambda value: self.fail(value))
            self.assertFalse(report["passed"])
            self.assertEqual(report["requested_point"]["x"], "nan")


if __name__ == "__main__":
    unittest.main()
