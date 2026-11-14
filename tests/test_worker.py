"""The background voice pipeline must only return a validated target ID."""

from argparse import Namespace
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))
from control import worker


class TestVoiceWorker(unittest.TestCase):
    def setUp(self):
        self.args = Namespace(speech_model="base", language="auto", bonsai_url="http://127.0.0.1:1234/v1", bonsai_model="bonsai-local")
        self.request = {"type": "search", "request_id": "a", "sample_rate": 16000,
                        "pcm_base64": "AAA=", "targets": [{"id": "tab", "label": "Codex", "x": 123, "y": 456}]}

    def test_invalid_request_never_enters_argmax(self):
        invalid = [dict(self.request, pcm_base64="invalid!"), dict(self.request, sample_rate=True),
                   dict(self.request, sample_rate=16000.5), dict(self.request, request_id=["bad"]),
                   dict(self.request, type="click"), dict(self.request, targets=[]),
                   dict(self.request, extra="field")]
        for request in invalid:
            with self.subTest(request=request), patch.object(worker, "WhisperKitEngine") as engine, \
                 patch.object(worker, "BonsaiClient"), patch.object(worker.sys, "stdin", io.StringIO(json.dumps(request) + "\n")), \
                 redirect_stdout(io.StringIO()) as output:
                self.assertEqual(worker.run(self.args), 0)
                engine.return_value.transcribe_bytes.assert_not_called()
                records = [json.loads(line) for line in output.getvalue().splitlines()]
                self.assertEqual(records[-1]["type"], "error")
                self.assertIsInstance(records[-1].get("request_id"), (str, type(None)))

    def test_valid_job_returns_text_and_id_without_coordinates_or_actions(self):
        with patch.object(worker, "WhisperKitEngine") as engine, patch.object(worker, "BonsaiClient") as model, \
             patch.object(worker.sys, "stdin", io.StringIO(json.dumps(self.request) + "\n")), \
             redirect_stdout(io.StringIO()) as output:
            engine.return_value.transcribe_bytes.return_value = SimpleNamespace(text="Codex")
            model.return_value.select_target.return_value = SimpleNamespace(target_id="tab", reason="matching label")
            self.assertEqual(worker.run(self.args), 0)
            model.return_value.select_target.assert_called_once_with("Codex", [{"id": "tab", "label": "Codex"}])
        records = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([record["type"] for record in records], ["worker_ready", "transcript", "selection"])
        self.assertEqual(records[-1], {"type": "selection", "request_id": "a", "target_id": "tab", "reason": "matching label"})

    def test_startup_failure_is_nonzero_and_never_claims_ready(self):
        with patch.object(worker, "WhisperKitEngine", side_effect=RuntimeError("missing model")), \
             redirect_stdout(io.StringIO()) as output:
            self.assertEqual(worker.run(self.args), 1)
        self.assertEqual(json.loads(output.getvalue())["type"], "error")

    def test_oversized_protocol_message_stops_worker(self):
        with patch.object(worker, "WhisperKitEngine"), patch.object(worker, "BonsaiClient"), \
             patch.object(worker, "MAX_MESSAGE_CHARS", 10), \
             patch.object(worker.sys, "stdin", io.StringIO("x" * 11)), redirect_stdout(io.StringIO()) as output:
            self.assertEqual(worker.run(self.args), 1)
        self.assertIn("Oversized", output.getvalue())
