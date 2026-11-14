#!/usr/bin/env python3
"""Verify real offline OCR → Argmax → Bonsai → move-only routing.

Uses a generated image and synthesized local audio. It never opens the camera,
records the microphone, captures the screen, or moves/clicks the actual mouse.
"""

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import time
import wave

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
from control.bonsai import BonsaiClient
from control.coordinator import Coordinator
from stt import STTConfig
from stt.runtime import offline_command

NATIVE = ROOT / ".build/LocalControl.app/Contents/MacOS/GestureCamera"
NO_NETWORK = "(version 1)(allow default)(deny network*)"


def run_checked(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"{Path(command[0]).name} failed ({result.returncode}): {detail}")
    return result


def json_lines(output):
    events = []
    for line in output.splitlines():
        if line.strip():
            value = json.loads(line)
            if not isinstance(value, dict):
                raise ValueError("Expected JSON event object")
            events.append(value)
    return events


def server_policy():
    source = (ROOT / "scripts/start_bonsai.sh").read_text()
    match = re.search(r"^PROFILE='([^']+)'$", source, re.MULTILINE)
    if not match:
        raise RuntimeError("Could not verify the Bonsai launcher's network policy")
    return match.group(1)


def verify_network_denial(profile):
    probe = """import socket, sys
try:
    connection = socket.create_connection(('1.1.1.1', 443), timeout=1)
except PermissionError:
    sys.exit(0)
except OSError as error:
    print(str(error), file=sys.stderr)
    sys.exit(2)
else:
    connection.close()
    sys.exit(1)
"""
    result = subprocess.run(["/usr/bin/sandbox-exec", "-p", profile, sys.executable, "-c", probe],
                            capture_output=True, text=True, timeout=5)
    if result.returncode:
        raise RuntimeError("External socket denial was not proven: " + result.stderr.strip())


def stop_owned(process):
    if process is not None and process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        except ProcessLookupError:
            pass


def start_owned_server(log_path):
    # Use an isolated service, so a running desktop instance is neither used nor
    # stopped by verification. The brief bind only selects a currently free port.
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    log = log_path.open("w")
    process = subprocess.Popen(["bash", str(ROOT / "scripts/start_bonsai.sh"), "--port", str(port)],
                               stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    log.close()
    endpoint = f"http://127.0.0.1:{port}/v1"
    client = BonsaiClient(endpoint, "bonsai-local", timeout=1)
    deadline = time.monotonic() + 90
    try:
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError("Bonsai failed to start: " + log_path.read_text()[-4000:])
            try:
                client.check_model()
                return process, endpoint
            except Exception:
                time.sleep(0.2)
        raise RuntimeError("Local Bonsai startup exceeded 90 seconds")
    except BaseException:
        stop_owned(process)
        raise


def validate_routing(targets, worker_events, request_id):
    """Feed production events into the coordinator, capturing instead of acting."""
    selected_events = [e for e in worker_events if e.get("type") == "selection"]
    errors = [e for e in worker_events if e.get("type") == "error"]
    transcripts = [e for e in worker_events if e.get("type") == "transcript"]
    if errors:
        raise RuntimeError("Worker failed: " + json.dumps(errors, ensure_ascii=False))
    if len(selected_events) != 1 or len(transcripts) != 1:
        raise RuntimeError("Worker did not produce exactly one transcript and selection")
    selection = selected_events[0]
    if selection.get("request_id") != request_id or transcripts[0].get("request_id") != request_id:
        raise RuntimeError("Worker response does not match this recording")
    selected = next((target for target in targets if target["id"] == selection.get("target_id")), None)
    if selected is None or "codex" not in selected["label"].casefold():
        raise RuntimeError("Bonsai did not choose the generated Codex target")

    native_messages, jobs = [], []
    clock = lambda: 10.0
    coordinator = Coordinator(native_messages.append, jobs.append, clock=clock)
    # Put the simulated hand at the center of the generated text area, so all
    # native OCR alternatives are inside the coordinator's nearby-search region.
    center_x = (min(t["x"] - t["width"] / 2 for t in targets)
                + max(t["x"] + t["width"] / 2 for t in targets)) / 2
    center_y = (min(t["y"] - t["height"] / 2 for t in targets)
                + max(t["y"] + t["height"] / 2 for t in targets)) / 2
    pointer = {"type": "pointer", "tracked": True, "x": center_x, "y": center_y}
    coordinator.handle({"type": "state", "armed": True}, source="native")
    coordinator.handle(pointer, source="native")
    coordinator.handle({"type": "speech_start", "request_id": request_id}, source="native")
    coordinator.handle({"type": "targets", "request_id": request_id, "targets": targets}, source="native")
    coordinator.handle({"type": "speech_audio", "request_id": request_id,
                        "pcm_base64": "AAA=", "sample_rate": 16000}, source="native")
    if len(jobs) != 1:
        raise RuntimeError("Coordinator did not submit exactly one search")
    for event in worker_events:
        if event.get("type") in ("transcript", "selection", "error"):
            coordinator.handle(event, source="worker")
    actions = [message for message in native_messages if message.get("type") == "voice_action"]
    if len(actions) != 1 or actions[0].get("action") != "move_to":
        raise RuntimeError("Voice did not produce exactly one move-only instruction")
    move = actions[0]
    if (move.get("x"), move.get("y")) != (selected["x"], selected["y"]):
        raise RuntimeError("Mouse target coordinates differ from native OCR coordinates")
    return transcripts[0]["text"], selected, move


def verify(output_dir):
    output_dir.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    report = {"started_at": datetime.now(timezone.utc).isoformat(), "passed": False,
              "scope": "generated-image OCR, synthesized-audio STT, local model selection, captured move-only routing",
              "physical_camera_microphone_mouse_tested": False,
              "wifi_setting_changed": False}
    owned_server = None
    try:
        if not NATIVE.is_file():
            raise RuntimeError("Build first: bash scripts/build_gesture_app.sh")
        config = STTConfig(model_name="base", language="auto")
        if not config.is_offline_ready():
            raise RuntimeError("Prepare Argmax first: bash scripts/setup_models.sh --model base --language auto")
        policy = server_policy()
        verify_network_denial(offline_command(config)[2])
        verify_network_denial(policy)
        report["external_sockets_denied"] = {"argmax_profile": True, "bonsai_profile": True}
        native_result = run_checked(["/usr/bin/sandbox-exec", "-p", NO_NETWORK, str(NATIVE), "--ocr-self-test"], timeout=30)
        ocr = next(e for e in json_lines(native_result.stdout) if e.get("type") == "ocr_self_test")
        if ocr.get("passed") is not True or not ocr.get("targets"):
            raise RuntimeError("Native generated-image OCR failed")
        targets = ocr["targets"]
        report["native_ocr"] = ocr

        aiff, wav = output_dir / "codex-request.aiff", output_dir / "codex-request.wav"
        run_checked(["/usr/bin/sandbox-exec", "-p", NO_NETWORK, "/usr/bin/say", "-v", "Samantha",
                     "-o", str(aiff), "Find the Codex tab."], timeout=30)
        run_checked(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)], timeout=10)
        with wave.open(str(wav), "rb") as audio:
            if audio.getnchannels() != 1 or audio.getsampwidth() != 2 or audio.getframerate() != 16000:
                raise RuntimeError("Test audio does not have the expected PCM format")
            pcm = audio.readframes(audio.getnframes())
        owned_server, endpoint = start_owned_server(output_dir / "bonsai.log")
        request_id = "offline-pipeline-smoke"
        request = {"type": "search", "request_id": request_id, "targets": targets,
                   "sample_rate": 16000, "pcm_base64": base64.b64encode(pcm).decode("ascii")}
        command = [sys.executable, str(ROOT / "desktop.py"), "--worker", "--speech-model", "base", "--language", "auto",
                   "--bonsai-url", endpoint, "--bonsai-model", "bonsai-local"]
        result = run_checked(command, input=json.dumps(request) + "\n", timeout=90)
        worker_events = json_lines(result.stdout)
        transcript, selected, move = validate_routing(targets, worker_events, request_id)
        report.update({"passed": True, "transcript": transcript, "selected_target": selected,
                       "captured_instruction": move, "worker_events": worker_events,
                       "speech_model": "openai_whisper-base", "bonsai_model": "Ternary-Bonsai-2-2B-mlx-2bit",
                       "bonsai_service": "dedicated loopback-only process, stopped after verification",
                       "native_binary_sha256": hashlib.sha256(NATIVE.read_bytes()).hexdigest()})
        return report
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        stop_owned(owned_server)
        report["elapsed_seconds"] = round(time.monotonic() - started, 3)
        (output_dir / "offline-pipeline.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT / ".build/verification")
    args = parser.parse_args()
    try:
        report = verify(args.output_dir.resolve())
    except Exception as error:
        print(f"Offline pipeline verification failed: {error}", file=sys.stderr)
        return 1
    print(f"Argmax: {report['transcript']}")
    print(f"Bonsai target: {report['selected_target']['label']}")
    print("Captured instruction: move_to (no mouse input was sent)")
    print(f"Report: {args.output_dir.resolve() / 'offline-pipeline.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
