"""Verification fails when real worker output would violate the move-only contract."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("test_product_offline", ROOT / "scripts/test_product_offline.py")
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class TestProductPipelineVerifier(unittest.TestCase):
    def setUp(self):
        self.targets = [{"id": "tab", "label": "Codex", "x": 200.5, "y": 300.5, "width": 100, "height": 20}]
        self.events = [{"type": "worker_ready"},
                       {"type": "transcript", "request_id": "recording", "text": "Find the Codex tab."},
                       {"type": "selection", "request_id": "recording", "target_id": "tab", "reason": "Codex"}]

    def test_exact_ocr_coordinates_and_move_only_instruction(self):
        text, target, move = smoke.validate_routing(self.targets, self.events, "recording")
        self.assertEqual(text, "Find the Codex tab.")
        self.assertEqual(move["action"], "move_to")
        self.assertEqual((move["x"], move["y"]), (target["x"], target["y"]))

    def test_missing_duplicate_unknown_and_failed_outputs_are_not_passes(self):
        cases = [self.events[:2], self.events + [self.events[-1]],
                 [*self.events[:2], dict(self.events[-1], target_id="invented")],
                 self.events + [{"type": "error", "message": "failed"}],
                 [*self.events[:2], dict(self.events[-1], request_id="old-recording")]]
        for events in cases:
            with self.subTest(events=events), self.assertRaises(RuntimeError):
                smoke.validate_routing(self.targets, events, "recording")

    def test_failure_replaces_a_stale_success_report(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            report = output / "offline-pipeline.json"
            report.write_text('{"passed": true}')
            with patch.object(smoke, "NATIVE", output / "missing-native-app"):
                with self.assertRaisesRegex(RuntimeError, "Build first"):
                    smoke.verify(output)
            self.assertFalse(json.loads(report.read_text())["passed"])
