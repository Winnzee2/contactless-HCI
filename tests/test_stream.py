"""Regression coverage for Argmax's cumulative microphone snapshots."""

from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))
from stt.stream import WhisperKitStreamer
from test_engine import local_config


class TestWhisperKitStreamer(unittest.TestCase):
    def setUp(self):
        self.text = []
        self.partial = []
        self.stream = WhisperKitStreamer(on_text=self.text.append,
                                         on_partial_text=self.partial.append)

    def test_cumulative_snapshots_emit_each_segment_once(self):
        for line in ["Transcribing audio stream, press Ctrl+C to stop.", "---",
                     "Unconfirmed segment: scroll down", "Current text: please",
                     "---", "Confirmed segment: scroll down please", "Current text:",
                     "---", "Confirmed segment: scroll down please",
                     "Confirmed segment: scroll down please", "Current text:"]:
            self.stream._handle_line(line)
        # Repeated genuine utterances remain distinct; cumulative reprints do not.
        self.assertEqual(self.text, ["scroll down please", "scroll down please"])
        self.assertEqual(self.stream.get_text(timeout=0), "scroll down please")
        self.assertEqual(self.stream.get_text(timeout=0), "scroll down please")
        self.assertIsNone(self.stream.get_text(timeout=0))
        self.assertEqual(self.partial, ["scroll down please", ""])

    def test_logs_and_provisional_text_are_not_confirmed_transcripts(self):
        for line in ["Initializing models...", "IOSurface warning", "---",
                     "Unconfirmed segment: select this", "Current text: zoom in"]:
            self.stream._handle_line(line)
        self.assertEqual(self.text, [])
        self.assertIsNone(self.stream.get_text(timeout=0))
        self.assertTrue(self.partial)

    def test_command_like_speech_remains_literal_text(self):
        phrases = ["Scroll down, please.", "Type Hello, World!", "Search for local files.",
                   "Stop listening.", "Confirm and proceed."]
        for phrase in phrases:
            self.stream._handle_line(f"Confirmed segment: {phrase}")
        self.assertEqual(self.text, phrases)
        self.assertEqual([self.stream.get_text(timeout=0) for _ in phrases], phrases)
        self.assertIsNone(self.stream.get_text(timeout=0))

    def test_plain_text_is_queued_even_if_callback_fails(self):
        def fail(text):
            raise ValueError("consumer failed")
        stream = WhisperKitStreamer(on_text=fail)
        with self.assertLogs("stt.stream", level="ERROR"):
            stream._handle_line("Confirmed segment: Hello!")
        self.assertEqual(stream.get_text(timeout=0), "Hello!")

    def test_child_failure_is_reported_and_reaped(self):
        with tempfile.TemporaryDirectory() as folder:
            config = local_config(Path(folder))
            stream = WhisperKitStreamer(config)
            script = "import sys; print('Microphone permission denied', file=sys.stderr); sys.exit(2)"
            with patch("stt.stream.offline_command", return_value=[sys.executable, "-u", "-c", script]):
                try:
                    stream.start()
                    deadline = time.monotonic() + 5
                    while stream.is_running() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertFalse(stream.is_running())
                    with self.assertRaisesRegex(RuntimeError, "Microphone permission denied"):
                        stream.raise_if_failed()
                finally:
                    stream.stop()
            self.assertIsNone(stream._process)


if __name__ == "__main__":
    unittest.main()
