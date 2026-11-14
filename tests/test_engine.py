"""Asset validation, subprocess failures, and opt-in native inference tests."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))
from stt.audio_utils import get_audio_info, pad_audio_with_silence
from stt.config import STTConfig
from stt.engine import WhisperKitEngine
from stt.runtime import offline_command

ROOT = Path(__file__).resolve().parent.parent
SAMPLE = ROOT / "assets/samples/select_this_item.wav"


def local_config(root):
    config = STTConfig(model_name="tiny.en", models_dir=root, cli_binary=sys.executable)
    for model in ("AudioEncoder", "TextDecoder", "MelSpectrogram"):
        for name in ("model.mil", "coremldata.bin", "weights/weight.bin"):
            path = config.model_path / f"{model}.mlmodelc" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture")
    config.tokenizer_path.mkdir(parents=True)
    for name in ("tokenizer.json", "tokenizer_config.json", "config.json"):
        (config.tokenizer_path / name).write_text("{}")
    return config


class TestWhisperKitEngine(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config = local_config(Path(self.temp.name))

    def test_complete_assets(self):
        self.assertTrue(self.config.is_model_available())
        self.assertTrue(self.config.is_tokenizer_available())
        self.assertEqual(self.config.model_name, "openai_whisper-tiny.en")

    def test_canonical_base_model_uses_matching_tokenizer(self):
        config = STTConfig(model_name="openai_whisper-base.en", models_dir=Path(self.temp.name))
        self.assertEqual(config.tokenizer_name, "whisper-base.en")

    def test_incomplete_mel_model_rejected(self):
        (self.config.model_path / "MelSpectrogram.mlmodelc/weights/weight.bin").unlink()
        self.assertFalse(self.config.is_model_available())
        with self.assertRaises(FileNotFoundError), patch("stt.engine.subprocess.run") as run:
            WhisperKitEngine(self.config)
        run.assert_not_called()

    def test_missing_or_corrupt_tokenizer_config_rejected(self):
        path = self.config.tokenizer_path / "tokenizer_config.json"
        for content in ("", "not JSON", "[]"):
            path.write_text(content)
            self.assertFalse(self.config.is_tokenizer_available())
        path.unlink()
        with self.assertRaises(FileNotFoundError):
            WhisperKitEngine(self.config)

    def test_report_and_network_denial(self):
        paths = []
        def run(cmd, **kwargs):
            self.assertEqual(cmd[:3], ["/usr/bin/sandbox-exec", "-p",
                                      "(version 1)(allow default)(deny network*)"])
            self.assertNotIn("--model", cmd)
            self.assertEqual(kwargs["env"]["HF_HUB_OFFLINE"], "1")
            self.assertEqual(kwargs["timeout"], 120)
            audio = Path(cmd[cmd.index("--audio-path") + 1])
            report_dir = Path(cmd[cmd.index("--report-path") + 1])
            paths.extend([audio, report_dir])
            (report_dir / f"{audio.stem}.json").write_text(json.dumps({
                "text": "<|startoftranscript|>Select this item.<|endoftext|>",
                "segments": [{"id": 0, "text": "Select this item.", "start": 0, "end": 1}],
                "timings": {"fullPipeline": 0.05},
            }))
            (report_dir / "extra.log").write_text("temporary artifact")
            return subprocess.CompletedProcess(cmd, 0, "irrelevant log output", "")
        with patch("stt.engine.subprocess.run", side_effect=run):
            result = WhisperKitEngine(self.config).transcribe(SAMPLE, detailed=True)
        self.assertEqual(result.text, "Select this item.")
        self.assertEqual(len(result.segments), 1)
        self.assertIsNotNone(result.raw_report)
        self.assertTrue(all(not path.exists() for path in paths))

    def test_missing_report_does_not_turn_logs_into_speech(self):
        with patch("stt.engine.subprocess.run", return_value=subprocess.CompletedProcess([], 0, "Loading models", "")):
            with self.assertRaisesRegex(RuntimeError, "did not produce"):
                WhisperKitEngine(self.config).transcribe(SAMPLE)

    def test_timeout_and_process_error(self):
        with patch("stt.engine.subprocess.run", side_effect=subprocess.TimeoutExpired("argmax", 120)):
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                WhisperKitEngine(self.config).transcribe(SAMPLE)
        with patch("stt.engine.subprocess.run", return_value=subprocess.CompletedProcess([], 1, "", "CoreML failed")):
            with self.assertRaisesRegex(RuntimeError, "CoreML failed"):
                WhisperKitEngine(self.config).transcribe(SAMPLE)

    def test_deleted_assets_revalidated_before_transcription(self):
        engine = WhisperKitEngine(self.config)
        (self.config.tokenizer_path / "config.json").unlink()
        with patch("stt.engine.subprocess.run") as run, self.assertRaises(FileNotFoundError):
            engine.transcribe(SAMPLE)
        run.assert_not_called()

    def test_audio_padding(self):
        padded = Path(self.temp.name) / "padded.wav"
        pad_audio_with_silence(SAMPLE, padded)
        self.assertAlmostEqual(get_audio_info(padded)["duration"] - get_audio_info(SAMPLE)["duration"], 0.6, places=3)


@unittest.skipUnless(os.environ.get("STT_INTEGRATION") == "1", "Set STT_INTEGRATION=1 for native CoreML tests")
class TestNativeOfflineInference(unittest.TestCase):
    def test_local_samples_with_network_denied(self):
        for model in ("tiny.en", "base.en"):
            engine = WhisperKitEngine(STTConfig(model_name=model))
            for filename, word in (("select_this_item.wav", "select"), ("confirm_and_proceed.wav", "confirm")):
                with self.subTest(model=model, audio=filename):
                    result = engine.transcribe(ROOT / "assets/samples" / filename)
                    self.assertIn(word, result.text.lower())
                    self.assertGreater(result.audio_duration, 0)

    def test_network_policy_rejects_sockets(self):
        command = offline_command(STTConfig())[:3]
        script = "import socket; s = socket.socket(); s.connect(('1.1.1.1', 443))"
        result = subprocess.run(command + [sys.executable, "-c", script], capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Operation not permitted", result.stderr)


if __name__ == "__main__":
    unittest.main()
