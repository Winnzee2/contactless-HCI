"""Public entry points expose transcription without interpreting spoken words."""

import argparse
from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import cli
from stt import TranscriptionResult, TranscriptionSegment


class TestTextOnlyCLI(unittest.TestCase):
    def test_entry_points_show_transcription_tools(self):
        for entry in ("cli.py", "main.py"):
            for arguments in ([], ["--help"]):
                with self.subTest(entry=entry, arguments=arguments):
                    result = subprocess.run(
                        [sys.executable, str(ROOT / entry), *arguments],
                        capture_output=True, text=True, timeout=10,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    choices = re.search(r"\{([^{}]+)\}", result.stdout)
                    self.assertIsNotNone(choices, result.stdout)
                    self.assertEqual(set(choices.group(1).split(",")),
                                     {"check", "transcribe", "stream"})

    def test_removed_action_modes_are_rejected(self):
        for entry in ("cli.py", "main.py"):
            for mode in ("commands", "demo"):
                with self.subTest(entry=entry, mode=mode):
                    result = subprocess.run(
                        [sys.executable, str(ROOT / entry), mode],
                        input="", capture_output=True, text=True, timeout=10,
                    )
                    self.assertEqual(result.returncode, 2, result.stdout)
                    self.assertIn("invalid choice", result.stderr)

    def test_json_preserves_command_like_speech_as_text(self):
        phrase = "Scroll down, then type Hello World."
        result = TranscriptionResult(
            text=phrase,
            segments=[TranscriptionSegment(id=0, text=phrase, start=0, end=2)],
            audio_duration=2, pipeline_duration=0.1, model_name="openai_whisper-tiny.en",
        )
        args = argparse.Namespace(
            audio=str(ROOT / "assets/samples/select_this_item.wav"), model="tiny.en",
            no_pad=False, detailed=True, json=True,
        )
        output = io.StringIO()
        with patch.object(cli, "WhisperKitEngine") as engine, \
             redirect_stdout(output), redirect_stderr(io.StringIO()):
            engine.return_value.transcribe.return_value = result
            cli.cmd_transcribe(args)
        payload = json.loads(output.getvalue())
        self.assertEqual(payload["text"], phrase)
        self.assertEqual(payload["segments"][0]["text"], phrase)
        self.assertNotIn("action", payload)
        self.assertNotIn("command", payload)
        self.assertNotIn("parameter", payload)

    def test_stream_uses_only_text_callbacks(self):
        class TextOnlyStream:
            # A strict signature prevents the CLI from wiring an action callback.
            def __init__(self, config, *, on_text, on_partial_text):
                self.on_text = on_text
                self.on_partial_text = on_partial_text

            def __enter__(self):
                self.on_partial_text("scroll")
                self.on_text("Scroll down.")
                return self

            def __exit__(self, *args):
                pass

            def is_running(self):
                return False

            def raise_if_failed(self):
                pass

        output = io.StringIO()
        with patch.object(cli, "WhisperKitStreamer", TextOnlyStream), redirect_stdout(output):
            cli.cmd_stream(argparse.Namespace(model="tiny.en"))
        self.assertIn("Scroll down.", output.getvalue())
        self.assertIn("scroll", output.getvalue())
        self.assertNotIn("ACTION", output.getvalue())


if __name__ == "__main__":
    unittest.main()
