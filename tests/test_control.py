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

    def test_close_tab_requires_matching_native_acknowledgment(self):
        self.submit()
        self.coordinator.handle({"type": "navigation", "request_id": "a", "action": "close_tab"}, source="worker")
        self.assertEqual(self.native[-1], {"type": "voice_action", "request_id": "a", "action": "close_tab"})
        self.coordinator.handle({"type": "action", "source": "voice", "request_id": "a", "action": "tab_right"}, source="native")
        self.assertIsNotNone(self.coordinator.pending_navigation)
        self.coordinator.handle({"type": "action", "source": "voice", "request_id": "a", "action": "close_tab"}, source="native")
        self.assertIsNone(self.coordinator.pending_navigation)

    def test_window_commands_need_matching_action_ack(self):
        for action in ("close_window", "change_window", "all_windows"):
            self.setUp()
            self.submit()
            self.coordinator.handle({"type": "navigation", "request_id": "a", "action": action}, source="worker")
            self.assertEqual(self.native[-1], {"type": "voice_action", "request_id": "a", "action": action})
            self.coordinator.handle({"type": "action", "source": "voice", "request_id": "a", "action": "close_tab"}, source="native")
            self.assertIsNotNone(self.coordinator.pending_navigation)
            self.coordinator.handle({"type": "action", "source": "voice", "request_id": "a", "action": action}, source="native")
            self.assertIsNone(self.coordinator.pending_navigation)

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

    def test_voice_caption_uses_current_worker_transcript_without_moving_pointer(self):
        self.submit()
        self.coordinator.handle({"type": "transcript", "request_id": "a", "text": "Codex"}, source="worker")
        self.assertEqual(self.native[-1], {"type": "voice_feedback", "request_id": "a", "text": "Codex"})
        self.assertFalse(any(event["type"] == "voice_action" for event in self.native))
        self.assertEqual(self.coordinator.pointer, (500, 300))

    def test_voice_caption_rejects_stale_empty_and_wrong_source_transcripts(self):
        self.submit()
        for key, text, source in (("old", "Codex", "worker"), ("a", "Codex", "native"),
                                  ("a", "  ", "worker"), ("a", None, "worker")):
            self.coordinator.handle({"type": "transcript", "request_id": key, "text": text}, source=source)
        self.assertFalse(any(event["type"] == "voice_feedback" for event in self.native))
        self.coordinator.handle({"type": "state", "armed": False}, source="native")
        self.coordinator.handle({"type": "transcript", "request_id": "a", "text": "Codex"}, source="worker")
        self.assertFalse(any(event["type"] == "voice_feedback" for event in self.native))

    def test_selection_only_moves_to_ocr_coordinates(self):
        self.submit()
        self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1", "x": 9999})
        moves = [x for x in self.native if x["type"] == "voice_action"]
        self.assertEqual(len(moves), 1)
        self.assertEqual(moves[0]["action"], "move_to")
        self.assertEqual((moves[0]["x"], moves[0]["y"]), (550, 300))

    def test_target_status_waits_for_native_movement_confirmation(self):
        self.submit()
        self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"}, source="worker")
        self.assertEqual(self.coordinator.last_target, "")
        self.assertEqual(self.coordinator.pending_move.request_id, "a")
        statuses = [event["message"] for event in self.native if event["type"] == "status"]
        self.assertEqual(statuses[-1], "Moving to Codex…")
        self.assertFalse(any(message.startswith("Target:") for message in statuses))
        ack = {"type": "action", "source": "voice", "action": "move_to", "request_id": "a"}
        self.coordinator.handle(ack, source="native")
        self.assertEqual(self.coordinator.last_target, "Codex")
        self.assertIsNone(self.coordinator.pending_move)
        self.assertEqual(self.native[-1]["message"], "Target: Codex. Pinch middle / ring finger to click.")
        count = len(self.native)
        self.coordinator.handle(ack, source="native")
        self.assertEqual(len(self.native), count)

    def test_cancelled_native_wait_cannot_overwrite_new_prompt(self):
        self.submit()
        self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"}, source="worker")
        self.coordinator.handle({"type": "context_changed"}, source="native")
        self.coordinator.handle({"type": "speech_start", "request_id": "b"}, source="native")
        count = len(self.native)
        self.coordinator.handle({"type": "error", "request_id": "a", "message": "Old wait expired"}, source="native")
        self.assertEqual(len(self.native), count)
        self.assertIn("b", self.coordinator.pending)

    def test_wrong_or_forged_action_cannot_confirm_movement(self):
        self.submit()
        self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"}, source="worker")
        ack = {"type": "action", "source": "voice", "action": "move_to", "request_id": "a"}
        for event, source in ((dict(ack, request_id="old"), "native"),
                              (dict(ack, action="click"), "native"), (ack, "worker")):
            self.coordinator.handle(event, source=source)
            self.assertEqual(self.coordinator.last_target, "")
            self.assertEqual(self.coordinator.pending_move.request_id, "a")

    def test_native_move_error_prevents_late_success_status(self):
        for key in ("a", None):
            with self.subTest(request_id=key):
                self.setUp()
                self.submit()
                self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"}, source="worker")
                self.coordinator.handle({"type": "error", "request_id": key, "message": "Target changed"}, source="native")
                self.assertIsNone(self.coordinator.pending_move)
                self.coordinator.handle({"type": "action", "source": "voice", "action": "move_to", "request_id": "a"}, source="native")
                self.assertEqual(self.coordinator.last_target, "")
                self.assertEqual(self.native[-1]["message"], "Target changed")

    def test_late_movement_cannot_overwrite_new_search_status(self):
        self.submit()
        self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"}, source="worker")
        self.coordinator.handle({"type": "speech_start", "request_id": "b"}, source="native")
        self.assertIsNone(self.coordinator.pending_move)
        old_ack = {"type": "action", "source": "voice", "action": "move_to", "request_id": "a"}
        count = len(self.native)
        self.coordinator.handle(old_ack, source="native")
        self.assertEqual(len(self.native), count)
        target = dict(self.target, id="t2", label="Safari")
        self.coordinator.handle({"type": "targets", "request_id": "b", "targets": [target]}, source="native")
        self.coordinator.handle({"type": "speech_audio", "request_id": "b", "pcm_base64": "AAA=", "sample_rate": 16000}, source="native")
        self.coordinator.handle({"type": "selection", "request_id": "b", "target_id": "t2"}, source="worker")
        self.coordinator.handle(old_ack, source="native")
        self.assertEqual(self.coordinator.last_target, "")
        self.assertEqual(self.coordinator.pending_move.request_id, "b")
        self.coordinator.handle(dict(old_ack, request_id="b"), source="native")
        self.assertEqual(self.coordinator.last_target, "Safari")

    def test_invalidated_move_cannot_claim_success_after_reacquisition(self):
        events = ({"type": "state", "armed": False}, {"type": "context_changed"})
        for event in events:
            with self.subTest(event=event):
                self.setUp()
                self.submit()
                self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"}, source="worker")
                self.coordinator.handle(event, source="native")
                self.coordinator.handle({"type": "state", "armed": True}, source="native")
                self.point()
                self.coordinator.handle({"type": "action", "source": "voice", "action": "move_to", "request_id": "a"}, source="native")
                self.assertIsNone(self.coordinator.pending_move)
                self.assertEqual(self.coordinator.last_target, "")

    def test_unconfirmed_move_expires_with_a_live_hand(self):
        self.submit()
        self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"}, source="worker")
        for _ in range(80):
            self.now += .25
            self.point()
        self.assertIsNone(self.coordinator.pending_move)
        self.assertEqual(self.native[-1]["message"], "Pointer movement was not confirmed. Point and speak again.")
        self.coordinator.handle({"type": "action", "source": "voice", "action": "move_to", "request_id": "a"}, source="native")
        self.assertEqual(self.coordinator.last_target, "")

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

    def test_brief_hand_loss_defers_result_until_return(self):
        self.submit()
        self.coordinator.handle({"type": "pointer", "tracked": False})
        self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"}, source="worker")
        self.assertFalse(any(x["type"] == "voice_action" for x in self.native))
        self.assertIsNotNone(self.coordinator.deferred_result)
        self.now += 1
        self.point()
        self.assertEqual(sum(x["type"] == "voice_action" for x in self.native), 1)
        self.point()
        self.assertEqual(sum(x["type"] == "voice_action" for x in self.native), 1)

    def test_deferred_result_timeout_and_deliberate_cancellation(self):
        for end in ("timeout", "pause", "click", "context"):
            with self.subTest(end=end):
                self.setUp()
                self.submit()
                self.coordinator.handle({"type": "pointer", "tracked": False})
                self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"}, source="worker")
                if end == "timeout":
                    self.now += 5.1
                elif end == "pause":
                    self.coordinator.handle({"type": "state", "armed": False})
                elif end == "click":
                    self.coordinator.handle({"type": "action", "source": "gesture", "action": "click"}, source="native")
                else:
                    self.coordinator.handle({"type": "context_changed"}, source="native")
                self.point()
                self.assertIsNone(self.coordinator.deferred_result)
                self.assertFalse(any(x["type"] == "voice_action" for x in self.native))

    def test_paused_never_starts_capture_but_tracking_gap_does(self):
        self.coordinator.handle({"type": "state", "armed": False})
        self.begin()
        self.assertEqual(self.coordinator.pending, {})
        self.coordinator.handle({"type": "state", "armed": True})
        self.now += 1
        self.begin()
        self.assertIn("a", self.coordinator.pending)

    def test_screen_center_allows_speech_before_first_hand(self):
        self.coordinator.last_pointer = None
        self.coordinator.pointer = None
        self.coordinator.handle({"type": "ready", "screen_width": 1000, "screen_height": 700})
        self.begin()
        self.assertEqual((self.coordinator.pending["a"].x, self.coordinator.pending["a"].y), (500, 350))

    def test_navigation_without_worker_source_cannot_be_deferred(self):
        self.submit()
        self.coordinator.handle({"type": "pointer", "tracked": False})
        self.coordinator.handle({"type": "navigation", "request_id": "a", "action": "close_window"})
        self.point()
        self.assertIsNone(self.coordinator.deferred_result)
        self.assertFalse(any(x["type"] == "voice_action" for x in self.native))

    def test_outside_region_and_nonfinite_targets_filtered(self):
        self.begin()
        targets = [dict(self.target, id="bad1", x=9999), dict(self.target, id="bad2", x=float("nan")), self.target]
        self.coordinator.handle({"type": "targets", "request_id": "a", "targets": targets})
        self.assertEqual(self.coordinator.pending["a"].targets, [self.target])

    def test_cancel_does_not_queue_work_but_empty_capture_can_transcribe_navigation(self):
        self.begin()
        self.coordinator.handle({"type": "speech_cancel", "request_id": "a"})
        self.coordinator.handle({"type": "speech_audio", "request_id": "a", "pcm_base64": "AAA=", "sample_rate": 16000})
        self.assertEqual(self.worker, [])
        self.begin()
        self.coordinator.handle({"type": "targets", "request_id": "a", "targets": []})
        self.coordinator.handle({"type": "speech_audio", "request_id": "a", "pcm_base64": "AAA=", "sample_rate": 16000})
        self.assertEqual(len(self.worker), 1)
        self.assertEqual(self.worker[0]["targets"], [])
        self.coordinator.handle({"type": "navigation", "request_id": "a", "action": "back"}, source="worker")
        self.assertEqual([event for event in self.native if event["type"] == "voice_action"],
                         [{"type": "voice_action", "action": "back", "request_id": "a"}])

    def test_empty_capture_without_navigation_remains_a_noop(self):
        self.begin()
        self.coordinator.handle({"type": "targets", "request_id": "a", "targets": []}, source="native")
        self.coordinator.handle({"type": "speech_audio", "request_id": "a", "pcm_base64": "AAA=", "sample_rate": 16000}, source="native")
        self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": None}, source="worker")
        self.assertFalse(any(event["type"] == "voice_action" for event in self.native))
        self.assertIn("No named controls", self.native[-1]["message"])

    def test_back_navigation_waits_for_matching_native_ack_and_cannot_repeat(self):
        self.submit()
        event = {"type": "navigation", "request_id": "a", "action": "back"}
        self.coordinator.handle(event, source="worker")
        self.assertEqual(self.native[-1], {"type": "voice_action", "action": "back", "request_id": "a"})
        self.assertEqual(self.coordinator.pending_navigation.request_id, "a")
        self.assertIsNone(self.coordinator.pending_move)
        self.assertEqual(self.coordinator.pending, {})
        self.assertIsNone(self.coordinator.worker_request)
        self.assertFalse(any(item.get("message") == "Back navigation sent." for item in self.native))
        self.coordinator.handle(event, source="worker")
        self.assertEqual(len([item for item in self.native if item["type"] == "voice_action"]), 1)
        ack = {"type": "action", "source": "voice", "action": "back", "request_id": "a"}
        for incorrect, source in ((dict(ack, request_id="old"), "native"),
                                  (dict(ack, action="move_to"), "native"), (ack, "worker")):
            self.coordinator.handle(incorrect, source=source)
            self.assertIsNotNone(self.coordinator.pending_navigation)
        self.coordinator.handle(ack, source="native")
        self.assertIsNone(self.coordinator.pending_navigation)
        self.assertEqual(self.native[-1]["message"], "Back navigation sent.")
        self.assertEqual(self.coordinator.last_target, "")
        count = len(self.native)
        self.coordinator.handle(ack, source="native")
        self.assertEqual(len(self.native), count)

    def test_navigation_requires_worker_source_valid_action_and_submitted_request(self):
        for source in ("native", None, "unknown"):
            with self.subTest(source=source):
                self.setUp()
                self.submit()
                self.coordinator.handle({"type": "navigation", "request_id": "a", "action": "back"}, source=source)
                self.assertIn("a", self.coordinator.pending)
                self.assertEqual(self.coordinator.worker_request, "a")
                self.assertFalse(any(event["type"] == "voice_action" for event in self.native))
        for fields in ({"action": "forward"}, {"action": "click"}, {"action": ["tab_left"]},
                       {"action": "back", "keys": ["cmd", "q"]},
                       {"action": "tab_left", "x": 12}, {"action": "tab_right", "target_id": "t1"},
                       {"action": "tab_right", "keys": ["cmd", "q"]}):
            with self.subTest(fields=fields):
                self.setUp()
                self.submit()
                self.coordinator.handle({"type": "navigation", "request_id": "a", **fields}, source="worker")
                self.assertFalse(any(event["type"] == "voice_action" for event in self.native))
                self.assertIsNone(self.coordinator.pending_navigation)
        self.setUp()
        self.begin()
        self.coordinator.handle({"type": "navigation", "request_id": "a", "action": "back"}, source="worker")
        self.assertFalse(any(event["type"] == "voice_action" for event in self.native))

    def test_tab_navigation_needs_no_label_and_confirms_only_the_requested_direction(self):
        for direction in ("left", "right"):
            with self.subTest(direction=direction):
                self.setUp()
                action = "tab_" + direction
                self.begin()
                self.coordinator.handle({"type": "targets", "request_id": "a", "targets": []}, source="native")
                self.coordinator.handle({"type": "speech_audio", "request_id": "a", "pcm_base64": "AAA=",
                                         "sample_rate": 16000}, source="native")
                event = {"type": "navigation", "request_id": "a", "action": action}
                self.coordinator.handle(event, source="native")
                self.assertEqual(self.coordinator.worker_request, "a")
                self.assertFalse(any(item["type"] == "voice_action" for item in self.native))
                self.coordinator.handle(event, source="worker")
                self.assertEqual(self.native[-1], {"type": "voice_action", "action": action, "request_id": "a"})
                self.assertEqual(self.coordinator.pending_navigation.action, action)
                self.assertEqual(self.native[-2]["message"], f"Switching to the tab on the {direction}…")
                ack = {"type": "action", "source": "voice", "action": action, "request_id": "a"}
                opposite = "tab_right" if direction == "left" else "tab_left"
                for wrong in (dict(ack, action=opposite), dict(ack, action="back"), dict(ack, request_id="old")):
                    self.coordinator.handle(wrong, source="native")
                    self.assertEqual(self.coordinator.pending_navigation.action, action)
                self.coordinator.handle(ack, source="worker")
                self.assertIsNotNone(self.coordinator.pending_navigation)
                self.coordinator.handle(ack, source="native")
                self.assertIsNone(self.coordinator.pending_navigation)
                self.assertEqual(self.native[-1]["message"], f"Tab {direction} shortcut sent.")
                count = len(self.native)
                self.coordinator.handle(event, source="worker")
                self.coordinator.handle(ack, source="native")
                self.assertEqual(len(self.native), count)
                self.assertEqual(self.coordinator.last_target, "")

    def test_stale_tab_ack_cannot_confirm_a_new_opposite_direction(self):
        self.submit()
        self.coordinator.handle({"type": "navigation", "request_id": "a", "action": "tab_left"}, source="worker")
        self.coordinator.handle({"type": "speech_start", "request_id": "b"}, source="native")
        self.coordinator.handle({"type": "targets", "request_id": "b", "targets": []}, source="native")
        self.coordinator.handle({"type": "speech_audio", "request_id": "b", "pcm_base64": "AAA=",
                                 "sample_rate": 16000}, source="native")
        self.coordinator.handle({"type": "navigation", "request_id": "b", "action": "tab_right"}, source="worker")
        for request_id, action in (("a", "tab_left"), ("a", "tab_right"), ("b", "tab_left")):
            self.coordinator.handle({"type": "action", "source": "voice", "request_id": request_id,
                                     "action": action}, source="native")
            self.assertEqual(self.coordinator.pending_navigation.request_id, "b")
            self.assertEqual(self.coordinator.pending_navigation.action, "tab_right")
        self.coordinator.handle({"type": "action", "source": "voice", "request_id": "b",
                                 "action": "tab_right"}, source="native")
        self.assertIsNone(self.coordinator.pending_navigation)
        self.assertEqual(self.native[-1]["message"], "Tab right shortcut sent.")

    def test_tab_navigation_obeys_pause_tracking_and_expiry_cancellation(self):
        for action in ("tab_left", "tab_right"):
            for end in ("pause", "hand_loss", "expiry"):
                with self.subTest(action=action, end=end):
                    self.setUp()
                    self.submit()
                    if end == "pause":
                        self.coordinator.handle({"type": "state", "armed": False}, source="native")
                    elif end == "hand_loss":
                        self.coordinator.handle({"type": "pointer", "tracked": False}, source="native")
                    else:
                        for _ in range(84):
                            self.now += .25
                            self.point()
                    self.coordinator.handle({"type": "navigation", "request_id": "a", "action": action}, source="worker")
                    self.assertFalse(any(item["type"] == "voice_action" for item in self.native))
                    self.assertIsNone(self.coordinator.pending_navigation)
                    self.assertIsNone(self.coordinator.worker_request)

    def test_stale_navigation_is_cancelled_without_releasing_worker_backpressure_early(self):
        for cancellation in ({"type": "state", "armed": False}, {"type": "context_changed"}):
            with self.subTest(cancellation=cancellation):
                self.setUp()
                self.submit()
                self.coordinator.handle(cancellation, source="native")
                self.coordinator.handle({"type": "state", "armed": True}, source="native")
                self.point()
                self.coordinator.handle({"type": "speech_start", "request_id": "b"}, source="native")
                self.assertNotIn("b", self.coordinator.pending)
                self.coordinator.handle({"type": "navigation", "request_id": "a", "action": "back"}, source="worker")
                self.assertFalse(any(event["type"] == "voice_action" for event in self.native))
                self.coordinator.handle({"type": "speech_start", "request_id": "b"}, source="native")
                self.assertIn("b", self.coordinator.pending)

    def test_navigation_confirmation_is_cleared_by_new_search_error_pause_and_timeout(self):
        for end in ("new", "error", "pause", "timeout"):
            with self.subTest(end=end):
                self.setUp()
                self.submit()
                self.coordinator.handle({"type": "navigation", "request_id": "a", "action": "back"}, source="worker")
                if end == "new":
                    self.coordinator.handle({"type": "speech_start", "request_id": "b"}, source="native")
                elif end == "error":
                    self.coordinator.handle({"type": "error", "request_id": "a", "message": "No previous page"}, source="native")
                elif end == "pause":
                    self.coordinator.handle({"type": "state", "armed": False}, source="native")
                else:
                    for _ in range(80):
                        self.now += .25
                        self.point()
                self.assertIsNone(self.coordinator.pending_navigation)
                count = len(self.native)
                self.coordinator.handle({"type": "action", "source": "voice", "action": "back", "request_id": "a"}, source="native")
                self.assertEqual(len(self.native), count)

    def test_expired_request_cannot_navigate_after_transcription(self):
        self.submit()
        for _ in range(84):
            self.now += .25
            self.point()
        self.coordinator.handle({"type": "navigation", "request_id": "a", "action": "back"}, source="worker")
        self.assertFalse(any(event["type"] == "voice_action" for event in self.native))
        self.assertIsNone(self.coordinator.worker_request)

    def test_reacquiring_hand_preserves_current_selection(self):
        self.submit()
        self.coordinator.handle({"type": "pointer", "tracked": False})
        self.point()
        self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"})
        self.assertTrue(any(x["type"] == "voice_action" for x in self.native))

    def test_gesture_actions_cancel_screen_context(self):
        for action in ("click", "right_click", "double_click", "mission_control"):
            with self.subTest(action=action):
                self.setUp()
                self.submit()
                self.coordinator.handle({"type": "action", "source": "gesture", "action": action}, source="native")
                self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"}, source="worker")
                self.assertFalse(any(x["type"] == "voice_action" for x in self.native))

    def test_gesture_preparation_preserves_audio_and_capture(self):
        self.begin()
        self.coordinator.handle({"type": "gesture_cancel", "source": "gesture"}, source="native")
        self.coordinator.handle({"type": "targets", "request_id": "a", "targets": [self.target]}, source="native")
        self.coordinator.handle({"type": "speech_audio", "request_id": "a", "pcm_base64": "AAA=", "sample_rate": 16000}, source="native")
        self.assertIn("a", self.coordinator.pending)
        self.assertEqual(len(self.worker), 1)
        self.assertFalse(any(x["type"] == "voice_action" for x in self.native))

    def test_gesture_preparation_preserves_result_and_worker_backpressure(self):
        self.submit()
        self.coordinator.handle({"type": "gesture_cancel", "source": "gesture"}, source="native")
        self.coordinator.handle({"type": "speech_start", "request_id": "b"}, source="native")
        self.assertIn("a", self.coordinator.pending)
        self.assertEqual(self.coordinator.worker_request, "a")
        self.coordinator.handle({"type": "selection", "request_id": "a", "target_id": "t1"}, source="worker")
        self.assertTrue(any(x["type"] == "voice_action" for x in self.native))
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

    def test_full_screen_region_keeps_distant_candidates(self):
        self.coordinator.handle({"type": "ready", "screen_width": 1000, "screen_height": 700}, source="native")
        self.coordinator.handle({"type": "pointer", "tracked": True, "x": 20, "y": 20})
        self.begin()
        target = dict(self.target, x=950, y=650)
        self.coordinator.handle({"type": "targets", "request_id": "a", "targets": [target],
                                 "region": {"x": 0, "y": 0, "width": 1000, "height": 700}})
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
        self.coordinator.handle({"type": "context_changed"})
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
