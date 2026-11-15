#!/usr/bin/env python3
"""Local Control: offline hand mouse + voice-to-screen-text targeting."""

import argparse
import json
import os
from pathlib import Path
from queue import Empty, Queue
import signal
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "src"))
from control.bonsai import BonsaiClient
from control.coordinator import Coordinator
from stt import STTConfig

APP = ROOT / ".build/LocalControl.app/Contents/MacOS/GestureCamera"
MAX_EVENT_CHARS = 3000000


def app_is_current():
    """Rebuild when native source or packaging changed since the executable."""
    if not APP.is_file():
        return False
    built_at = APP.stat().st_mtime_ns
    inputs = tuple(ROOT / path for path in (
        "native/GestureCamera.swift", "native/ScreenTargets.swift", "native/TargetOverlay.swift", "native/DuplicateTargetOverlay.swift",
        "native/HandGestures.swift", "native/NotesPanel.swift", "native/DesktopActions.swift", "native/Info.plist",
        "scripts/build_gesture_app.sh"))
    return all(path.is_file() and path.stat().st_mtime_ns <= built_at for path in inputs)


def stop_process(process):
    if process is None:
        return
    # These processes are started in private groups. Kill descendants even if
    # their parent has already failed (e.g. a worker with Argmax still running).
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=3)
    for channel in (process.stdin, process.stdout):
        if channel:
            try:
                channel.close()
            except (OSError, ValueError):
                pass


def send(process, payload):
    if process is None or process.poll() is not None:
        raise RuntimeError("A local component has stopped")
    process.stdin.write(json.dumps(payload, ensure_ascii=False) + "\n")
    process.stdin.flush()


def reader(process, kind, events):
    try:
        while True:
            line = process.stdout.readline(MAX_EVENT_CHARS + 1)
            if not line:
                break
            if len(line) > MAX_EVENT_CHARS:
                events.put((kind, {"type": "error", "message": "Local component sent an oversized event."}))
                break
            try:
                value = json.loads(line)
                if isinstance(value, dict):
                    events.put((kind, value))
            except ValueError:
                # Never parse diagnostic stdout as executable control messages.
                print(line.rstrip(), file=sys.stderr)
    except (OSError, ValueError):
        # The application can close the pipe during shutdown.
        pass
    finally:
        events.put((kind, {"type": "closed"}))


def ensure_bonsai(args):
    client = BonsaiClient(args.bonsai_url, args.bonsai_model, timeout=2)
    try:
        client.check_model()
        return None  # Existing services belong to their owner and are left running.
    except Exception:
        if (args.no_start_bonsai or args.bonsai_url.rstrip("/") != "http://127.0.0.1:1234/v1"
                or args.bonsai_model != "bonsai-local"):
            raise
    print("Starting the installed local Bonsai model…", file=sys.stderr)
    process = subprocess.Popen(["bash", str(ROOT / "scripts/start_bonsai.sh")],
                               stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
                               start_new_session=True)
    try:
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError("Bonsai failed to start; inspect the local runtime error above.")
            try:
                client.check_model()
                return process
            except Exception:
                time.sleep(0.3)
        raise RuntimeError("Bonsai did not become ready within 90 seconds.")
    except BaseException:
        # Includes Ctrl+C while loading; no orphan model server is left behind.
        stop_process(process)
        raise


def native_readiness(voice=True):
    """Return native readiness and diagnostics without requesting permissions."""
    result = subprocess.run([str(APP), "--check"], capture_output=True, text=True, timeout=15)
    if result.returncode != 0:
        return False, f"Native check failed: {result.stderr.strip() or result.stdout.strip()}"
    try:
        records = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
        checks = [entry for entry in records if isinstance(entry, dict) and entry.get("type") == "check"]
        if len(checks) != 1:
            raise ValueError("Expected a single native check response")
        state = checks[0]
    except ValueError:
        return False, "Native check returned invalid diagnostics"
    count = state.get("camera_count")
    ready = (state.get("camera_authorization") == "authorized"
             and type(count) is int and count > 0 and state.get("accessibility") is True)
    if voice:
        ready = ready and state.get("microphone_authorization") == "authorized" and state.get("screen_recording") is True
    return ready, json.dumps(state, ensure_ascii=False)


def check(args):
    built = APP.is_file()
    current = app_is_current()
    print(f"Native desktop app: {'current' if current else 'needs rebuild' if built else 'not built'}")
    ready = current
    if built:
        permissions_ready, details = native_readiness(voice=not args.gesture_only)
        print(details)
        ready = ready and permissions_ready
        if not permissions_ready:
            print("Native devices/permissions: not ready (open the app and grant the requested macOS permissions)")
    if args.gesture_only:
        print("Gesture-only mode: Argmax, microphone, Screen Recording, and Bonsai are not required.")
    else:
        config = STTConfig(model_name=args.speech_model, language=args.language)
        speech_ready = config.is_offline_ready()
        print(f"Argmax assets ({args.speech_model}): {'ready' if speech_ready else 'missing'}")
        ready = ready and speech_ready
        try:
            BonsaiClient(args.bonsai_url, args.bonsai_model, timeout=3).check_model()
            print("Bonsai local model: ready")
        except Exception as error:
            print(f"Bonsai local model: {error}")
            ready = False
    return 0 if ready else 1


def run(args):
    if not app_is_current():
        subprocess.run(["bash", str(ROOT / "scripts/build_gesture_app.sh")], check=True)
        if not APP.is_file():
            raise RuntimeError("Native build completed without creating the desktop app")
    server = native = worker = None
    events = Queue()
    try:
        if not args.gesture_only:
            config = STTConfig(model_name=args.speech_model, language=args.language)
            if not config.is_offline_ready():
                raise RuntimeError(f"Prepare Argmax first: bash scripts/setup_models.sh --model {args.speech_model} --language auto")
            server = ensure_bonsai(args)
            worker_cmd = [sys.executable, str(ROOT / "desktop.py"), "--worker", "--speech-model", args.speech_model,
                          "--language", args.language, "--bonsai-url", args.bonsai_url,
                          "--bonsai-model", args.bonsai_model]
            worker = subprocess.Popen(worker_cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      text=True, bufsize=1, start_new_session=True)
            threading.Thread(target=reader, args=(worker, "worker", events), daemon=True).start()
        native = subprocess.Popen([str(APP)] + ([] if args.gesture_only else ["--voice"]),
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
                                  start_new_session=True)
        threading.Thread(target=reader, args=(native, "native", events), daemon=True).start()
        coordinator = Coordinator(lambda value: send(native, value), lambda value: send(worker, value))
        coordinator.set_voice_ready(False)
        print("Local Control is open. Enable control in its window; Escape pauses, Q quits.", flush=True)
        while native.poll() is None:
            try:
                source, event = events.get(timeout=0.1)
            except Empty:
                coordinator.expire()
                continue
            kind = event.get("type")
            if kind in ("exit", "closed") and source == "native":
                break
            if kind == "closed" and source == "worker":
                coordinator.set_voice_ready(False)
                coordinator.status("Speech worker stopped. Restart the app to use voice targeting.", important=True)
                continue
            if kind == "worker_ready" and source == "worker":
                coordinator.set_voice_ready(True)
                coordinator.status("Offline voice targeting ready. Point near a label, then say its name.")
            elif kind == "ready" and source == "native":
                coordinator.handle(event, source=source)
                coordinator.status("Index finger moves. Thumb + middle: left; thumb + ring: right.")
            else:
                coordinator.handle(event, source=source)
                if kind in ("transcript", "selection", "error", "action"):
                    print(json.dumps(event, ensure_ascii=False), flush=True)
        # Read the real exit status rather than assuming a closed stdout means success.
        try:
            code = native.wait(timeout=3)
        except subprocess.TimeoutExpired:
            return 1
        return 0 if code == 0 else 1
    except KeyboardInterrupt:
        return 0
    finally:
        stop_process(native)
        stop_process(worker)
        stop_process(server)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Inspect local assets and permissions")
    parser.add_argument("--gesture-only", action="store_true", help="Run camera and hand mouse without microphone/Bonsai")
    parser.add_argument("--speech-model", default="base", help="Argmax model; base supports Chinese and English")
    parser.add_argument("--language", default="auto", help="Speech language, e.g. auto, en, zh")
    parser.add_argument("--bonsai-url", default="http://127.0.0.1:1234/v1")
    parser.add_argument("--bonsai-model", default="bonsai-local")
    parser.add_argument("--no-start-bonsai", action="store_true", help="Require an already-running local server")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        if args.worker:
            from control.worker import run as run_worker
            return run_worker(args)
        return check(args) if args.check else run(args)
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Local Control: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
