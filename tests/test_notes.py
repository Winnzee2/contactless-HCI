"""Jarvis routing, silence timing, buffering and note/command isolation."""
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))
from control.notes import Notes, wake_text, note_text
from control.coordinator import Coordinator


class TestNotes(unittest.TestCase):
    def setUp(self):
        self.now = 10.
        self.native, self.worker = [], []
        self.notes = Notes(self.native.append, self.worker.append, lambda: self.now)

    def audio(self, key):
        self.notes.observe({"type": "speech_start", "request_id": key}, "native")
        self.notes.observe({"type": "speech_audio", "request_id": key,
                            "pcm_base64": "AAA=", "sample_rate": 16000}, "native")

    def result(self, key, text):
        self.notes.observe({"type": "dictation", "request_id": key, "text": text}, "worker")

    def begin(self, text="Hey Jarvis"):
        self.audio("wake")
        self.notes.begin("wake", text)

    def test_commands_strip_only_wake_prefix_and_stop_marker(self):
        self.assertEqual(wake_text("Hey, Jarvis! Write this down."), "Write this down.")
        self.assertIsNone(wake_text("Do not say hey Jarvis"))
        self.assertIsNone(wake_text("Hey Jarvison"))
        self.assertEqual(note_text("A reminder. Bye Jarvis. Ignore this."), ("A reminder.", True))

    def test_argmax_stop_homophones_are_limited_to_the_end(self):
        self.assertEqual(note_text("Remember milk, buy Jarvis."), ("Remember milk,", True))
        self.assertEqual(note_text("Remember milk. By Jarvis."), ("Remember milk.", True))
        self.assertEqual(note_text("Buy Jarvis merchandise tomorrow."), ("Buy Jarvis merchandise tomorrow.", False))

    def test_same_block_wake_content_and_stop(self):
        self.begin("Hey Jarvis. Buy milk. Bye Jarvis.")
        self.assertFalse(self.notes.busy)
        self.assertEqual(self.native[-1]["text"], "Buy milk.")
        self.assertTrue(self.native[-1]["final"])
        self.assertEqual(self.worker, [])
        self.assertTrue(self.native[-1]["close_after_save"])

    def test_bye_requests_close_but_silence_does_not(self):
        self.begin()
        self.audio("content")
        self.result("content", "Remember this. Bye Jarvis.")
        self.assertTrue(self.native[-1]["final"])
        self.assertTrue(self.native[-1]["close_after_save"])
        self.begin("Hey Jarvis, another note")
        self.now += 6
        self.notes.tick()
        self.assertTrue(self.native[-1]["final"])
        self.assertFalse(self.native[-1]["close_after_save"])

    def test_audio_while_wake_is_transcribing_is_not_lost(self):
        self.audio("wake")
        self.audio("next")
        self.notes.begin("wake", "Hey Jarvis")
        self.assertEqual(self.worker[-1]["request_id"], "next")
        self.result("next", "Remember the meeting.")
        self.assertEqual(self.native[-1]["text"], "Remember the meeting.")

    def test_silence_waits_for_pending_transcription_before_saving(self):
        self.begin()
        self.audio("a")
        self.now += 5
        self.notes.tick()
        self.assertFalse(self.notes.accepting)
        self.assertTrue(self.notes.busy)
        self.assertFalse(self.native[-1]["final"])
        self.result("a", "This was spoken before the timeout.")
        self.assertTrue(self.native[-1]["final"])
        self.assertIn("before the timeout", self.native[-1]["text"])

    def test_continuous_activity_keeps_recording_alive(self):
        self.begin()
        for _ in range(20):
            self.now += 1
            self.notes.observe({"type": "speech_activity"}, "native")
            self.notes.tick()
        self.assertTrue(self.notes.accepting)
        self.now += 4.9
        self.notes.tick()
        self.assertTrue(self.notes.accepting)
        self.now += .1
        self.notes.tick()
        self.assertFalse(self.notes.busy)

    def test_blocks_are_serial_and_navigation_is_just_text(self):
        self.begin()
        self.audio("a")
        self.audio("b")
        self.assertEqual(len(self.worker), 1)
        self.result("a", "Close window.")
        self.assertEqual(self.worker[-1]["type"], "dictate")
        self.assertEqual(self.worker[-1]["request_id"], "b")
        self.result("b", "Tab left. Bye Jarvis.")
        self.assertEqual(self.native[-1]["text"], "Close window.\nTab left.")
        self.assertFalse(any(x["type"] == "voice_action" for x in self.native))

    def test_bye_discards_audio_recorded_after_the_stop_phrase(self):
        self.begin()
        self.audio("a")
        self.audio("b")
        self.result("a", "Done. Bye Jarvis.")
        self.assertEqual(len(self.worker), 1)
        self.assertFalse(self.notes.busy)
        self.assertEqual(self.native[-1]["text"], "Done.")

    def test_clicks_and_app_changes_do_not_cancel_note(self):
        self.begin()
        for kind in ("action", "context_changed", "gesture_cancel"):
            self.assertTrue(self.notes.observe({"type": kind}, "native"))
        self.assertTrue(self.notes.accepting)

    def test_pause_saves_recognized_text(self):
        self.begin("Hey Jarvis. Existing note.")
        self.notes.observe({"type": "state", "armed": False}, "native")
        self.assertTrue(self.native[-1]["final"])
        self.assertEqual(self.native[-1]["text"], "Existing note.")

    def test_failure_saves_partial_and_does_not_claim_complete(self):
        self.begin("Hey Jarvis. Existing note.")
        self.audio("a")
        self.notes.observe({"type": "error", "request_id": "a"}, "worker")
        self.assertTrue(self.native[-1]["final"])
        self.assertIn("failed", self.native[-1]["message"])
        self.assertEqual(self.native[-1]["text"], "Existing note.")

    def test_backlog_is_bounded_and_reported(self):
        self.begin()
        for n in range(15):
            self.audio(str(n))
        self.assertFalse(self.notes.accepting)
        self.assertLessEqual(len(self.notes.queue), 12)
        self.assertIn("could not keep up", self.notes.reason)

    def test_worker_timeout_does_not_wait_forever(self):
        self.begin("Hey Jarvis. First.")
        self.audio("a")
        self.now += 46
        self.notes.tick()
        self.assertFalse(self.notes.busy)
        self.assertTrue(self.native[-1]["final"])
        self.assertIn("timed out", self.native[-1]["message"])

    def test_coordinator_routes_wake_without_hand_or_screen_action(self):
        coordinator = Coordinator(self.native.append, self.worker.append, clock=lambda: self.now)
        coordinator.handle({"type": "state", "armed": True}, source="native")
        coordinator.handle({"type": "ready", "screen_width": 1000, "screen_height": 700}, source="native")
        coordinator.handle({"type": "speech_start", "request_id": "wake"}, source="native")
        coordinator.handle({"type": "targets", "request_id": "wake", "targets": []}, source="native")
        coordinator.handle({"type": "speech_audio", "request_id": "wake", "pcm_base64": "AAA=", "sample_rate": 16000}, source="native")
        coordinator.handle({"type": "jarvis", "request_id": "wake", "text": "Hey Jarvis"}, source="worker")
        self.assertTrue(coordinator.notes.busy)
        self.assertEqual(coordinator.pending, {})
        coordinator.handle({"type": "speech_start", "request_id": "note"}, source="native")
        coordinator.handle({"type": "speech_audio", "request_id": "note", "pcm_base64": "AAA=", "sample_rate": 16000}, source="native")
        self.assertEqual(self.worker[-1]["type"], "dictate")
        coordinator.handle({"type": "dictation", "request_id": "note", "text": "Close window. Bye Jarvis"}, source="worker")
        self.assertTrue(self.native[-1]["final"])
        self.assertFalse(any(x["type"] == "voice_action" for x in self.native))

    def test_unrelated_worker_errors_remain_visible_to_coordinator(self):
        self.assertFalse(self.notes.observe({"type": "error", "message": "Startup failed"}, "worker"))
        self.assertEqual(self.native, [])

    def test_worker_exit_finishes_partial_note(self):
        coordinator = Coordinator(self.native.append, self.worker.append, clock=lambda: self.now)
        coordinator.notes.begin("wake", "Hey Jarvis. Save this.")
        coordinator.set_voice_ready(False)
        self.assertFalse(coordinator.notes.busy)
        self.assertTrue(any(x.get("final") and x.get("text") == "Save this." for x in self.native))

    def test_busy_audio_queue_still_expires_stalled_transcription(self):
        coordinator = Coordinator(self.native.append, self.worker.append, clock=lambda: self.now)
        coordinator.notes.begin("wake", "Hey Jarvis. Partial.")
        for event in ({"type": "speech_start", "request_id": "a"},
                      {"type": "speech_audio", "request_id": "a", "pcm_base64": "AAA=", "sample_rate": 16000}):
            coordinator.handle(event, source="native")
        for _ in range(46):
            self.now += 1
            coordinator.handle({"type": "speech_activity"}, source="native")
        self.assertFalse(coordinator.notes.busy)
        self.assertIn("timed out", self.native[-1]["message"])

    def test_forged_wake_cannot_open_note(self):
        coordinator = Coordinator(self.native.append, self.worker.append, clock=lambda: self.now)
        coordinator.handle({"type": "jarvis", "request_id": "unknown", "text": "Hey Jarvis"}, source="worker")
        self.assertFalse(coordinator.notes.busy)
