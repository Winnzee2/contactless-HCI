"""
Unit tests for STTConfig and WhisperKitEngine.
"""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from stt.audio_utils import get_audio_info, pad_audio_with_silence
from stt.config import STTConfig
from stt.engine import WhisperKitEngine


class TestWhisperKitEngine(unittest.TestCase):
    def test_config_paths(self):
        config = STTConfig(model_name="tiny.en")
        self.assertTrue(config.is_cli_available(), "whisperkit-cli must be installed")
        self.assertTrue(config.is_model_available(), "tiny.en model must be downloaded")
        self.assertTrue(config.is_tokenizer_available(), "tokenizer must be downloaded")
        self.assertTrue(config.is_offline_ready(), "System must be 100% offline ready")

    def test_health_check(self):
        config = STTConfig(model_name="tiny.en")
        engine = WhisperKitEngine(config)
        status = engine.health_check()
        self.assertTrue(status["offline_ready"])
        self.assertEqual(status["model_name"], "openai_whisper-tiny.en")

    def test_audio_padding(self):
        sample = Path(__file__).resolve().parent.parent / "assets" / "samples" / "zoom_in.wav"
        if sample.exists():
            padded = pad_audio_with_silence(sample)
            self.assertTrue(padded.exists())
            info_orig = get_audio_info(sample)
            info_padded = get_audio_info(padded)
            self.assertGreater(info_padded["duration"], info_orig["duration"])
            padded.unlink()

    def test_offline_transcription(self):
        sample = Path(__file__).resolve().parent.parent / "assets" / "samples" / "select_this_item.wav"
        if sample.exists():
            config = STTConfig(model_name="tiny.en")
            engine = WhisperKitEngine(config)
            res = engine.transcribe(sample)
            self.assertIn("select", res.text.lower())
            self.assertGreater(res.audio_duration, 0.5)
            self.assertGreater(res.pipeline_duration, 0.0)


if __name__ == "__main__":
    unittest.main()
