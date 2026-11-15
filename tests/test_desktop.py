"""Desktop readiness and lifecycle checks without launching devices or models."""

from argparse import Namespace
from contextlib import redirect_stdout, redirect_stderr
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import desktop


def args(**changes):
    values = dict(speech_model="base", language="auto", gesture_only=False,
                  bonsai_url="http://127.0.0.1:1234/v1", bonsai_model="bonsai-local",
                  no_start_bonsai=False)
    values.update(changes)
    return Namespace(**values)


def diagnostics(**changes):
    state = dict(type="check", camera_authorization="authorized", camera_count=1,
                 microphone_authorization="authorized", accessibility=True, screen_recording=True)
    state.update(changes)
    return subprocess.CompletedProcess([], 0, json.dumps(state), "")


class TestDesktopReadiness(unittest.TestCase):
    def test_missing_permissions_do_not_report_ready(self):
        for name, value in (("camera_authorization", "denied"), ("camera_count", 0),
                            ("microphone_authorization", "denied"), ("accessibility", False),
                            ("screen_recording", False)):
            with self.subTest(permission=name), patch.object(desktop, "APP") as app, \
                 patch.object(desktop, "app_is_current", return_value=True), \
                 patch.object(desktop.subprocess, "run", return_value=diagnostics(**{name: value})), \
                 patch.object(desktop, "STTConfig") as config, patch.object(desktop, "BonsaiClient"), \
                 redirect_stdout(io.StringIO()):
                app.is_file.return_value = True
                config.return_value.is_offline_ready.return_value = True
                self.assertEqual(desktop.check(args()), 1)

    def test_gesture_only_needs_no_speech_assets_or_screen_permission(self):
        with patch.object(desktop, "APP") as app, patch.object(desktop, "app_is_current", return_value=True), \
             patch.object(desktop.subprocess, "run", return_value=diagnostics(microphone_authorization="denied", screen_recording=False)), \
             patch.object(desktop, "STTConfig") as speech, patch.object(desktop, "BonsaiClient") as model, \
             redirect_stdout(io.StringIO()):
            app.is_file.return_value = True
            self.assertEqual(desktop.check(args(gesture_only=True)), 0)
            speech.assert_not_called()
            model.assert_not_called()

    def test_invalid_native_response_fails_readiness(self):
        for result in (subprocess.CompletedProcess([], 1, "", "failed"),
                       subprocess.CompletedProcess([], 0, "not json", ""),
                       subprocess.CompletedProcess([], 0, '{"type":"ready"}', "")):
            with patch.object(desktop.subprocess, "run", return_value=result):
                ready, _ = desktop.native_readiness()
                self.assertFalse(ready)

    def test_modified_native_input_triggers_rebuild(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "app"
            app.write_text("binary")
            paths = [root / "native/GestureCamera.swift", root / "native/ScreenTargets.swift",
                     root / "native/TargetOverlay.swift",
                     root / "native/Info.plist", root / "scripts/build_gesture_app.sh"]
            for path in paths:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("source")
                os.utime(path, (10, 10))
            os.utime(app, (20, 20))
            with patch.object(desktop, "ROOT", root), patch.object(desktop, "APP", app):
                self.assertTrue(desktop.app_is_current())
                os.utime(paths[1], (30, 30))
                self.assertFalse(desktop.app_is_current())


class TestDesktopLifecycle(unittest.TestCase):
    def test_existing_bonsai_is_not_owned_by_launcher(self):
        with patch.object(desktop, "BonsaiClient"), patch.object(desktop.subprocess, "Popen") as popen:
            self.assertIsNone(desktop.ensure_bonsai(args()))
            popen.assert_not_called()

    def test_model_loading_interrupt_cleans_started_service(self):
        process = MagicMock()
        process.poll.return_value = None
        with patch.object(desktop, "BonsaiClient") as model, \
             patch.object(desktop.subprocess, "Popen", return_value=process), \
             patch.object(desktop.time, "sleep", side_effect=KeyboardInterrupt), \
             patch.object(desktop, "stop_process") as stop, redirect_stderr(io.StringIO()):
            model.return_value.check_model.side_effect = RuntimeError("starting")
            with self.assertRaises(KeyboardInterrupt):
                desktop.ensure_bonsai(args())
            stop.assert_called_once_with(process)

    def test_native_start_failure_cleans_worker_and_owned_server(self):
        server, worker = MagicMock(), MagicMock()
        with patch.object(desktop, "app_is_current", return_value=True), \
             patch.object(desktop, "STTConfig") as config, \
             patch.object(desktop, "ensure_bonsai", return_value=server), \
             patch.object(desktop.subprocess, "Popen", side_effect=[worker, OSError("native failed")]), \
             patch.object(desktop.threading, "Thread"), patch.object(desktop, "stop_process") as stop:
            config.return_value.is_offline_ready.return_value = True
            with self.assertRaisesRegex(OSError, "native failed"):
                desktop.run(args())
            self.assertIn(unittest.mock.call(worker), stop.call_args_list)
            self.assertIn(unittest.mock.call(server), stop.call_args_list)

    def test_cleanup_signals_descendants_even_after_parent_exit(self):
        process = MagicMock()
        process.pid = 12345
        process.poll.return_value = 0
        with patch.object(desktop.os, "killpg") as kill:
            desktop.stop_process(process)
        kill.assert_called_once_with(12345, desktop.signal.SIGTERM)
        process.wait.assert_called_once_with(timeout=3)
