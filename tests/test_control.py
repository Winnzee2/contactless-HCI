"""Voice target routing and cancellation without camera/mouse access."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))
from control.coordinator import Coordinator


class TestCoordinator(unittest.TestCase):
    def setUp(self):
        self.now = 10.0
        self.native = []
        self.worker = []
        self.coordinator = Coordinator(self.native.append, self.worker.append, clock=lambda: self.now)
        self.coordinator.handle({"type": "state", "armed": True})
        self.point()
        self.target = {"id": "t1", "label": "Codex", "x": 550, "y": 300, "width": 100, "height": 20}

    def point(self):
        self.coordinator.handle({"type": "pointer", "tracked": True, "x": 500, "y": 300})

    def begin(self):
        self.coordinator.handle({"type": "speech_start", "request_id": "a"})

    def submit(self):
        self.begin()
        self.coordinator.handle({"type": "targets", "request_id": "a", "targets": [self.target]})
        self.coordinator.handle({"type": "speech_audio", "request_id": "a", "pcm_base64": "AAA=", "sample_rate": 16000})

    def test_target_and_audio_can_arrive_in_either_order(self):
        self.begin()
        self.coordinator.handle({"type": "speech_audio", "request_id": "a", "pcm_base64": "AAA=", "sample_rate": 16000})
        self.assertEqual(self.worker, [])
        self.coordinator.handle({"type": "targets", "request_id": "a", "targets": [self.target]})
        self.assertEqual(len(self.worker), 1)
        self.assertEqual(self.worker[0]["targets"], [self.target])
        # Duplicate audio must never submit the job again.
        self.coordinator.handle({"type": "speech_audio", "request_id": "a", "pcm_base64": "AAA=", "sample_rate": 16000})
        self.assertEqual(len(self.worker), 1)

    def test_selection_only_moves_to_ocr_coordinates(self):
        self.submit()
        self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1", "x": 9999})
        moves = [x for x in self.native if x["type"] == "voice_action"]
        self.assertEqual(len(moves), 1)
        self.assertEqual(moves[0]["action"], "move_to")
        self.assertEqual((moves[0]["x"], moves[0]["y"]), (550, 300))

    def test_unknown_or_missing_target_never_moves(self):
        for selection in ("not-visible", None):
            self.submit()
            self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": selection})
        self.assertFalse(any(x["type"] == "voice_action" for x in self.native))

    def test_disarm_cancels_inflight_selection_even_after_rearm(self):
        self.submit()
        self.coordinator.handle({"type": "state", "armed": False})
        self.coordinator.handle({"type": "state", "armed": True})
        self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"})
        self.assertFalse(any(x["type"] == "voice_action" for x in self.native))

    def test_tracking_loss_and_expiry_discard_selection(self):
        self.submit()
        self.coordinator.handle({"type": "pointer", "tracked": False})
        self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"})
        self.point()
        self.submit()
        self.now += 21
        self.point()
        self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"})
        self.assertFalse(any(x["type"] == "voice_action" for x in self.native))

    def test_no_hand_or_paused_never_starts_capture(self):
        self.coordinator.handle({"type": "state", "armed": False})
        self.begin()
        self.assertEqual(self.coordinator.pending, {})
        self.coordinator.handle({"type": "state", "armed": True})
        self.now += 1
        self.begin()
        self.assertEqual(self.coordinator.pending, {})

    def test_outside_region_and_nonfinite_targets_filtered(self):
        self.begin()
        targets = [dict(self.target, id="bad1", x=9999), dict(self.target, id="bad2", x=float("nan")), self.target]
        self.coordinator.handle({"type": "targets", "request_id": "a", "targets": targets})
        self.assertEqual(self.coordinator.pending["a"].targets, [self.target])

    def test_cancel_and_empty_ocr_do_not_queue_work(self):
        self.begin()
        self.coordinator.handle({"type": "speech_cancel", "request_id": "a"})
        self.coordinator.handle({"type": "speech_audio", "request_id": "a", "pcm_base64": "AAA=", "sample_rate": 16000})
        self.assertEqual(self.worker, [])
        self.begin()
        self.coordinator.handle({"type": "targets", "request_id": "a", "targets": []})
        self.coordinator.handle({"type": "speech_audio", "request_id": "a", "pcm_base64": "AAA=", "sample_rate": 16000})
        self.assertEqual(self.worker, [])

    def test_reacquiring_hand_does_not_revive_old_selection(self):
        self.submit()
        self.coordinator.handle({"type": "pointer", "tracked": False})
        self.point()
        self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"})
        self.assertFalse(any(x["type"] == "voice_action" for x in self.native))

    def test_gesture_actions_cancel_screen_context(self):
        for action in ("click", "right_click", "double_click", "mission_control"):
            with self.subTest(action=action):
                self.setUp()
                self.submit()
                self.coordinator.handle({"type": "action", "source": "gesture", "action": action}, source="native")
                self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"}, source="worker")
                self.assertFalse(any(x["type"] == "voice_action" for x in self.native))

    def test_gesture_intent_cancels_capture_before_any_click(self):
        self.begin()
        self.coordinator.handle({"type": "gesture_cancel", "source": "gesture"}, source="native")
        self.coordinator.handle({"type": "targets", "request_id": "a", "targets": [self.target]}, source="native")
        self.coordinator.handle({"type": "speech_audio", "request_id": "a", "pcm_base64": "AAA=", "sample_rate": 16000}, source="native")
        self.assertEqual(self.coordinator.pending, {})
        self.assertEqual(self.worker, [])
        self.assertFalse(any(x["type"] == "voice_action" for x in self.native))

    def test_gesture_intent_cancels_result_but_waits_for_running_worker(self):
        self.submit()
        self.coordinator.handle({"type": "gesture_cancel", "source": "gesture"}, source="native")
        self.coordinator.handle({"type": "speech_start", "request_id": "b"}, source="native")
        self.assertEqual(self.coordinator.pending, {})
        self.assertEqual(self.coordinator.worker_request, "a")
        self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"}, source="worker")
        self.assertFalse(any(x["type"] == "voice_action" for x in self.native))
        self.coordinator.handle({"type": "speech_start", "request_id": "b"}, source="native")
        self.assertIn("b", self.coordinator.pending)

    def test_worker_cannot_forge_gesture_intent_or_mission_control(self):
        self.submit()
        generation = self.coordinator.generation
        for event in ({"type": "gesture_cancel", "source": "gesture"},
                      {"type": "action", "source": "gesture", "action": "mission_control"},
                      {"type": "action", "source": "gesture", "action": "double_click"}):
            self.coordinator.handle(event, source="worker")
        self.assertEqual(self.coordinator.generation, generation)
        self.assertIn("a", self.coordinator.pending)
        self.assertFalse(any(x["type"] == "voice_action" for x in self.native))

    def test_clamped_screen_edge_region_keeps_valid_candidates(self):
        self.coordinator.handle({"type": "ready", "screen_width": 1000, "screen_height": 700}, source="native")
        self.coordinator.handle({"type": "pointer", "tracked": True, "x": 20, "y": 20})
        self.begin()
        target = dict(self.target, x=650, y=390)
        self.coordinator.handle({"type": "targets", "request_id": "a", "targets": [target],
                                 "region": {"x": 0, "y": 0, "width": 720, "height": 420}})
        self.assertEqual(self.coordinator.pending["a"].targets, [target])

    def test_unexpected_region_cancels_request(self):
        self.begin()
        self.coordinator.handle({"type": "targets", "request_id": "a", "targets": [self.target],
                                 "region": {"x": 9999, "y": 0, "width": 720, "height": 420}})
        self.assertEqual(self.coordinator.pending, {})

    def test_process_sources_cannot_forge_each_others_messages(self):
        self.coordinator.handle({"type": "state", "armed": False}, source="worker")
        self.assertTrue(self.coordinator.armed)
        self.submit()
        self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"}, source="native")
        self.assertFalse(any(x["type"] == "voice_action" for x in self.native))
        self.assertIn("a", self.coordinator.pending)

    def test_failed_worker_is_not_given_new_recordings(self):
        self.coordinator.set_voice_ready(False)
        self.begin()
        self.assertEqual(self.coordinator.pending, {})
        self.assertEqual(self.worker, [])

    def test_canceled_model_request_must_finish_before_new_search(self):
        self.submit()
        self.coordinator.handle({"type": "pointer", "tracked": False})
        self.point()
        self.coordinator.handle({"type": "speech_start", "request_id": "b"})
        self.assertEqual(self.coordinator.pending, {})
        self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"}, source="worker")
        self.coordinator.handle({"type": "speech_start", "request_id": "b"})
        self.assertIn("b", self.coordinator.pending)

    def test_duplicate_ocr_does_not_replace_submitted_target_coordinates(self):
        self.submit()
        self.coordinator.handle({"type": "targets", "request_id": "a", "targets": [dict(self.target, x=600)]})
        self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"})
        move = next(x for x in self.native if x["type"] == "voice_action")
        self.assertEqual(move["x"], 550)
