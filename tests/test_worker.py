"""The voice worker returns validated targets or an explicit navigation intent."""

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
from control.bonsai import SelectedTarget
from control.voice_commands import navigation_intent


class TestVoiceWorker(unittest.TestCase):
    def setUp(self):
        self.args = Namespace(speech_model="base", language="auto", bonsai_url="http://127.0.0.1:1234/v1", bonsai_model="bonsai-local")
        self.request = {"type": "search", "request_id": "a", "sample_rate": 16000,
                        "pcm_base64": "AAA=", "targets": [{"id": "tab", "label": "Codex", "x": 123, "y": 456}]}

    def test_invalid_request_never_enters_argmax(self):
        invalid = [dict(self.request, pcm_base64="invalid!"), dict(self.request, sample_rate=True),
                   dict(self.request, sample_rate=16000.5), dict(self.request, request_id=["bad"]),
                   dict(self.request, type="click"), dict(self.request, targets=[], type="choose"),
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
            model.return_value.select_target.return_value = SelectedTarget("tab", "matching label")
            self.assertEqual(worker.run(self.args), 0)
            model.return_value.select_target.assert_called_once_with("Codex", [{"id": "tab", "label": "Codex"}])
        records = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([record["type"] for record in records], ["worker_ready", "transcript", "selection"])
        self.assertEqual(records[-1], {"type": "selection", "request_id": "a", "target_id": "tab", "reason": "matching label"})

    def test_last_page_is_recognized_only_as_a_complete_phrase(self):
        for transcript in ("last page", "Last Page.", "LAST PAGE!", "  last   page?  ", "ＬＡＳＴ ＰＡＧＥ。"):
            with self.subTest(transcript=transcript):
                self.assertEqual(navigation_intent(transcript), "back")
        for transcript in ("", "Don't go to the last page", "never go to last page", "if I say last page",
                           "the last page was helpful", "last page and click", "last page two",
                           "last page; open settings", "last page\nclick", "back", "next page",
                           '"last page"', None, 1, "last page" + " " * 4000):
            with self.subTest(transcript=transcript):
                self.assertIsNone(navigation_intent(transcript))

    def test_last_page_bypasses_target_selection_in_both_request_modes(self):
        requests = [self.request, dict(self.request, targets=[]),
                    dict(self.request, type="choose", targets=[{"id": "left", "label": "1"},
                                                               {"id": "right", "label": "2"}])]
        for request in requests:
            with self.subTest(request=request), patch.object(worker, "WhisperKitEngine") as engine, \
                 patch.object(worker, "BonsaiClient") as model, \
                 patch.object(worker.sys, "stdin", io.StringIO(json.dumps(request) + "\n")), \
                 redirect_stdout(io.StringIO()) as output:
                engine.return_value.transcribe_bytes.return_value = SimpleNamespace(text="Last page.")
                self.assertEqual(worker.run(self.args), 0)
                self.assertEqual(engine.return_value.transcribe_bytes.call_count, 1)
                model.return_value.select_target.assert_not_called()
            records = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual([record["type"] for record in records], ["worker_ready", "transcript", "navigation"])
            self.assertEqual(records[-1], {"type": "navigation", "request_id": "a", "action": "back"})

    def test_natural_navigation_and_small_transcription_error(self):
        for phrase, action in (("Could you switch to the tab on the left please", "tab_left"),
                               ("Tap right.", "tab_right"), ("Please go back", "back"),
                               ("返回上一页", "back")):
            self.assertEqual(navigation_intent(phrase), action)
        for phrase in ("Do not tap left", "If I say tap right", "tap left and click"):
            self.assertIsNone(navigation_intent(phrase))

    def test_tab_navigation_requires_one_complete_direction_phrase(self):
        for transcript, expected in (("tab left", "tab_left"), ("Tab Right.", "tab_right"),
                                     ("  TAB   LEFT!  ", "tab_left"), ("ＴＡＢ ＲＩＧＨＴ。", "tab_right")):
            with self.subTest(transcript=transcript):
                self.assertEqual(navigation_intent(transcript), expected)
        for transcript in ("Don't tab left", "do not tab right", "if I say tab left", "the tab right of this one",
                           "tab left and click", "tab right then last page", "tab left or tab right",
                           "tab left; open settings", "tab right\nclick", "left tab", "next tab", '"tab right"'):
            with self.subTest(transcript=transcript):
                self.assertIsNone(navigation_intent(transcript))

    def test_tab_navigation_bypasses_target_matching_and_number_choice(self):
        requests = [self.request, dict(self.request, targets=[]),
                    dict(self.request, type="choose", targets=[{"id": "first", "label": "1"},
                                                               {"id": "second", "label": "2"}])]
        for transcript, expected in (("Tab left.", "tab_left"), ("Tab right!", "tab_right")):
            for request in requests:
                with self.subTest(transcript=transcript, request=request), patch.object(worker, "WhisperKitEngine") as engine, \
                     patch.object(worker, "BonsaiClient") as model, \
                     patch.object(worker.sys, "stdin", io.StringIO(json.dumps(request) + "\n")), \
                     redirect_stdout(io.StringIO()) as output:
                    engine.return_value.transcribe_bytes.return_value = SimpleNamespace(text=transcript)
                    self.assertEqual(worker.run(self.args), 0)
                    self.assertEqual(engine.return_value.transcribe_bytes.call_count, 1)
                    model.return_value.select_target.assert_not_called()
                records = [json.loads(line) for line in output.getvalue().splitlines()]
                self.assertEqual([record["type"] for record in records], ["worker_ready", "transcript", "navigation"])
                self.assertEqual(records[-1], {"type": "navigation", "request_id": "a", "action": expected})

    def test_mentions_and_negations_do_not_emit_navigation(self):
        for kind in ("search", "choose"):
            request = dict(self.request, type=kind, targets=[{"id": "one", "label": "1"}])
            for transcript in ("Do not go to last page", "If I say last page", "last page and click",
                               "Do not tab left", "If I say tab right", "tab right and click"):
                with self.subTest(kind=kind, transcript=transcript), patch.object(worker, "WhisperKitEngine") as engine, \
                     patch.object(worker, "BonsaiClient") as model, \
                     patch.object(worker.sys, "stdin", io.StringIO(json.dumps(request) + "\n")), \
                     redirect_stdout(io.StringIO()) as output:
                    engine.return_value.transcribe_bytes.return_value = SimpleNamespace(text=transcript)
                    model.return_value.select_target.return_value = SelectedTarget(None, "No match")
                    self.assertEqual(worker.run(self.args), 0)
                records = [json.loads(line) for line in output.getvalue().splitlines()]
                self.assertEqual(records[-1]["type"], "selection")
                self.assertIsNone(records[-1]["target_id"])

    def test_empty_screen_still_transcribes_without_producing_a_target(self):
        request = dict(self.request, targets=[])
        with patch.object(worker, "WhisperKitEngine") as engine, \
             patch.object(worker, "BonsaiClient") as model, \
             patch.object(worker.sys, "stdin", io.StringIO(json.dumps(request) + "\n")), \
             redirect_stdout(io.StringIO()) as output:
            engine.return_value.transcribe_bytes.return_value = SimpleNamespace(text="Codex")
            model.return_value.select_target.return_value = SelectedTarget(None, "empty transcript or candidate list")
            self.assertEqual(worker.run(self.args), 0)
            model.return_value.select_target.assert_called_once_with("Codex", [])
        records = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(records[-1]["type"], "selection")
        self.assertIsNone(records[-1]["target_id"])

    def test_ambiguous_job_returns_only_original_candidate_ids(self):
        request = dict(self.request, targets=[{"id": "left", "label": "Save"}, {"id": "right", "label": "Save"}])
        with patch.object(worker, "WhisperKitEngine") as engine, patch.object(worker, "BonsaiClient") as model, \
             patch.object(worker.sys, "stdin", io.StringIO(json.dumps(request) + "\n")), \
             redirect_stdout(io.StringIO()) as output:
            engine.return_value.transcribe_bytes.return_value = SimpleNamespace(text="Save")
            model.return_value.select_target.return_value = SelectedTarget(None, "duplicate", ("left", "right"))
            self.assertEqual(worker.run(self.args), 0)
        record = json.loads(output.getvalue().splitlines()[-1])
        self.assertEqual(record, {"type": "selection", "request_id": "a", "target_id": None,
                                  "reason": "duplicate", "candidate_ids": ["left", "right"]})

    def test_number_choice_runs_argmax_and_never_runs_bonsai_selection(self):
        request = dict(self.request, type="choose", targets=[{"id": "left", "label": "1"},
                                                             {"id": "right", "label": "2"}])
        for transcript, expected, cancelled in (("number two", "right", False), ("选第一个", "left", False),
                                                ("three", None, False), ("one or two", None, False),
                                                ("cancel", None, True)):
            with self.subTest(transcript=transcript), patch.object(worker, "WhisperKitEngine") as engine, \
                 patch.object(worker, "BonsaiClient") as model, \
                 patch.object(worker.sys, "stdin", io.StringIO(json.dumps(request) + "\n")), \
                 redirect_stdout(io.StringIO()) as output:
                engine.return_value.transcribe_bytes.return_value = SimpleNamespace(text=transcript)
                self.assertEqual(worker.run(self.args), 0)
                engine.return_value.transcribe_bytes.assert_called_once_with(bytes(48000), is_raw_pcm=True,
                                                                              sample_rate=16000, auto_pad_short_audio=False)
                model.return_value.select_target.assert_not_called()
            records = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual([record["type"] for record in records], ["worker_ready", "transcript", "selection"])
            self.assertEqual(records[1]["text"], transcript)
            self.assertEqual(records[2]["target_id"], expected)
            self.assertEqual(records[2].get("cancelled", False), cancelled)
            self.assertFalse(set(records[2]) - {"type", "request_id", "target_id", "reason", "cancelled"})

    def test_bad_number_labels_fail_before_argmax(self):
        for labels in (("Save", "Save"), ("1", "3"), ("2", "1"), ("1", "1"), ("01", "2")):
            request = dict(self.request, type="choose", targets=[{"id": str(i), "label": label}
                                                                  for i, label in enumerate(labels)])
            with self.subTest(labels=labels), patch.object(worker, "WhisperKitEngine") as engine, \
                 patch.object(worker, "BonsaiClient"), \
                 patch.object(worker.sys, "stdin", io.StringIO(json.dumps(request) + "\n")), \
                 redirect_stdout(io.StringIO()) as output:
                self.assertEqual(worker.run(self.args), 0)
                engine.return_value.transcribe_bytes.assert_not_called()
            self.assertEqual(json.loads(output.getvalue().splitlines()[-1])["type"], "error")

    def test_short_number_audio_keeps_every_sample_and_adds_only_silence(self):
        audio = b"\x01\x02" * 4000
        padded = worker.pad_number_audio(audio, 16000)
        self.assertEqual(padded, bytes(9600) + audio + bytes(30400))
        self.assertEqual(len(padded), 16000 * 2 * 1.5)
        long_audio = b"\x01\x02" * 32000
        self.assertIs(worker.pad_number_audio(long_audio, 16000), long_audio)

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
