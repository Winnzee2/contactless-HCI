"""Numbered duplicate targets stay bound to visible, fresh screen geometry."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))
from control.coordinator import Coordinator


class TestDuplicateChoices(unittest.TestCase):
    def setUp(self):
        self.now = 10.0
        self.native, self.worker = [], []
        self.coordinator = Coordinator(self.native.append, self.worker.append, clock=lambda: self.now)
        self.coordinator.handle({"type": "state", "armed": True}, source="native")
        self.point()
        self.targets = [
            {"id": "right", "label": "Open", "x": 650, "y": 200, "width": 80, "height": 30},
            {"id": "bottom", "label": "Open", "x": 400, "y": 360, "width": 80, "height": 30},
            {"id": "left", "label": "Open", "x": 350, "y": 200, "width": 80, "height": 30},
        ]

    def point(self, x=500, y=300):
        self.native_event("pointer", tracked=True, x=x, y=y)

    def advance(self, seconds):
        finish = self.now + seconds
        while self.now < finish:
            self.now = min(finish, self.now + .25)
            self.point()

    def native_event(self, kind, **fields):
        self.coordinator.handle({"type": kind, **fields}, source="native")

    def worker_event(self, kind, **fields):
        self.coordinator.handle({"type": kind, **fields}, source="worker")

    def audio(self, key):
        self.native_event("speech_audio", request_id=key, pcm_base64="AAA=", sample_rate=16000)

    def create_choices(self, key="name", acknowledge=True):
        self.native_event("speech_start", request_id=key)
        self.native_event("targets", request_id=key, targets=self.targets)
        self.audio(key)
        self.worker_event("selection", request_id=key, target_id=None,
                          candidate_ids=[target["id"] for target in self.targets])
        if acknowledge:
            self.native_event("choices_shown", choice_id=key)

    def choose(self, key="number", targets=None):
        self.native_event("speech_start", request_id=key)
        self.native_event("targets", request_id=key,
                          targets=self.targets if targets is None else targets)
        self.audio(key)

    def commands(self, kind):
        return [message for message in self.native if message["type"] == kind]

    def test_duplicates_show_every_target_in_stable_screen_order_without_moving(self):
        self.create_choices()
        message = self.commands("show_choices")[0]
        self.assertEqual(message["choice_id"], "name")
        self.assertEqual(message["request_id"], "name")
        self.assertEqual(message["duration"], 15)
        self.assertEqual([(option["number"], option["id"]) for option in message["options"]],
                         [(1, "left"), (2, "right"), (3, "bottom")])
        self.assertEqual(self.commands("voice_action"), [])
        # Mutating incoming/outgoing dictionaries cannot change displayed numbering.
        self.targets[0]["x"] = 700
        message["options"][0]["number"] = 99
        self.assertEqual(self.coordinator.choices.options[0].number, 1)
        self.assertEqual(self.coordinator.choices.options[1].x, 650)

    def test_all_hundred_candidates_are_numbered(self):
        self.targets = [dict(self.targets[0], id=str(index), x=170 + index * 5, width=4, height=4)
                        for index in range(100)]
        self.create_choices()
        options = self.commands("show_choices")[0]["options"]
        self.assertEqual(len(options), 100)
        self.assertEqual([option["number"] for option in options], list(range(1, 101)))

    def test_duplicate_or_unknown_ambiguity_ids_never_create_choices_or_move(self):
        for ids in (["left", "left"], ["left", "missing"], ["left"], [], ["left", 2], "left"):
            with self.subTest(ids=ids):
                self.setUp()
                self.native_event("speech_start", request_id="bad")
                self.native_event("targets", request_id="bad", targets=self.targets)
                self.audio("bad")
                self.worker_event("selection", request_id="bad", target_id=None, candidate_ids=ids)
                self.assertIsNone(self.coordinator.choices)
                self.assertEqual(self.commands("voice_action"), [])

    def test_ambiguous_payload_cannot_smuggle_a_selected_target(self):
        self.native_event("speech_start", request_id="bad")
        self.native_event("targets", request_id="bad", targets=self.targets)
        self.audio("bad")
        self.worker_event("selection", request_id="bad", target_id="left", candidate_ids=["left", "right"])
        self.assertIsNone(self.coordinator.choices)
        self.assertEqual(self.commands("voice_action"), [])

    def test_number_requires_native_ack_and_wrong_or_forged_ack_is_ignored(self):
        self.create_choices(acknowledge=False)
        self.native_event("choices_shown", choice_id="old")
        self.worker_event("choices_shown", choice_id="name")
        self.native_event("speech_start", request_id="early")
        self.assertNotIn("early", self.coordinator.pending)
        self.assertEqual(len(self.commands("capture_targets")), 1)
        self.native_event("choices_shown", choice_id="name")
        self.native_event("speech_start", request_id="ready")
        self.assertIn("ready", self.coordinator.pending)

    def test_number_recaptures_original_area_even_when_pointer_moves(self):
        self.create_choices()
        self.point(1000, 700)
        self.choose()
        capture = self.commands("capture_targets")[-1]
        self.assertEqual((capture["x"], capture["y"], capture["width"], capture["height"]),
                         (500, 300, 720, 420))
        self.assertEqual(capture["choice_id"], "name")
        self.assertEqual(self.worker[-1]["type"], "choose")
        self.assertEqual(self.worker[-1]["targets"], [
            {"id": "left", "label": "1"}, {"id": "right", "label": "2"}, {"id": "bottom", "label": "3"}])

    def test_revalidation_uses_fresh_bounds_and_keeps_numbering_when_native_ids_change(self):
        self.create_choices()
        fresh = [dict(target, id=f"new-{index}", x=target["x"] + 3, y=target["y"] + 2)
                 for index, target in enumerate(reversed(self.targets))]
        self.choose(targets=fresh)
        self.worker_event("selection", request_id="number", target_id="right", x=9999)
        commands = [command for command in self.native if command["type"] in ("clear_choices", "voice_action")]
        self.assertEqual([command["type"] for command in commands], ["clear_choices", "voice_action"])
        self.assertEqual(commands[0]["choice_id"], "name")
        self.assertEqual(commands[1]["choice_id"], "name")
        self.assertEqual((commands[1]["x"], commands[1]["y"]), (650, 200))
        self.assertEqual(commands[1]["action"], "move_to")
        self.assertEqual(commands[1]["label"], "Open")
        self.assertIsNone(self.coordinator.choices)
        self.assertEqual(self.coordinator.last_target, "")
        self.assertEqual(self.coordinator.pending_move.request_id, "number")
        self.native_event("action", source="voice", action="move_to", request_id="number")
        self.assertEqual(self.coordinator.last_target, "Open")
        self.assertIsNone(self.coordinator.pending_move)

    def test_changed_missing_or_ambiguous_elements_preserve_positions(self):
        variants = [
            self.targets[:-1],
            [dict(target, x=target["x"] + 30) for target in self.targets],
            [dict(target, width=target["width"] + 30) for target in self.targets],
            [dict(target, label="Close") for target in self.targets],
            self.targets + [dict(self.targets[0], id="duplicate-detection")],
        ]
        for fresh in variants:
            with self.subTest(fresh=fresh):
                self.setUp()
                self.create_choices()
                self.choose(targets=fresh)
                self.assertIsNotNone(self.coordinator.choices)
                self.assertEqual(self.worker[-1]["type"], "choose")
                self.worker_event("selection", request_id="number", target_id="right")
                self.assertEqual((self.commands("voice_action")[-1]["x"], self.commands("voice_action")[-1]["y"]), (650, 200))

    def test_distinct_original_positions_survive_merged_elements(self):
        self.targets = [dict(self.targets[0], id="a", x=350), dict(self.targets[0], id="b", x=360)]
        self.create_choices()
        self.choose(targets=[dict(self.targets[0], id="new", x=355)])
        self.assertIsNotNone(self.coordinator.choices)
        self.assertEqual(len(self.worker[-1]["targets"]), 2)

    def test_revalidation_normalizes_chinese_spaces_punctuation_and_unicode(self):
        self.targets = [dict(target, label="项 目 Ａ＆Ｂ") for target in self.targets]
        self.create_choices()
        self.choose(targets=[dict(target, label="项目 a and b") for target in self.targets])
        self.assertEqual(self.worker[-1]["type"], "choose")

    def test_invalid_number_keeps_same_choice_without_extending_deadline(self):
        self.create_choices()
        deadline = self.coordinator.choices.expires_at
        self.advance(5)
        self.choose()
        self.worker_event("selection", request_id="number", target_id=None)
        self.assertEqual(self.coordinator.choices.choice_id, "name")
        self.assertEqual(self.coordinator.choices.expires_at, deadline)
        self.native_event("choices_shown", choice_id="name")
        self.assertEqual(self.coordinator.choices.expires_at, deadline)
        self.assertEqual(self.commands("voice_action"), [])
        self.choose(key="retry")
        self.worker_event("selection", request_id="retry", target_id="bottom")
        self.assertEqual(len(self.commands("voice_action")), 1)

    def test_expiry_while_transcribing_never_moves_and_keeps_worker_backpressure(self):
        self.create_choices()
        self.advance(14)
        self.choose()
        self.advance(1)
        self.assertIsNone(self.coordinator.choices)
        self.assertEqual(self.coordinator.worker_request, "number")
        self.native_event("speech_start", request_id="blocked")
        self.assertNotIn("blocked", self.coordinator.pending)
        self.worker_event("selection", request_id="number", target_id="right")
        self.assertEqual(self.commands("voice_action"), [])
        self.native_event("speech_start", request_id="new-name")
        self.assertIn("new-name", self.coordinator.pending)
        self.assertIsNone(self.coordinator.pending["new-name"].choice_id)

    def test_voice_cancel_clears_choices_without_moving(self):
        self.create_choices()
        self.choose()
        self.worker_event("selection", request_id="number", target_id=None, cancelled=True)
        self.assertIsNone(self.coordinator.choices)
        self.assertEqual(self.commands("voice_action"), [])
        self.assertEqual(self.commands("clear_choices")[-1]["choice_id"], "name")

    def test_last_page_clears_choices_then_sends_only_bound_back_navigation(self):
        self.create_choices()
        self.choose()
        self.worker_event("navigation", request_id="number", action="back")
        commands = [command for command in self.native if command["type"] in ("clear_choices", "voice_action")]
        self.assertEqual(commands, [
            {"type": "clear_choices", "choice_id": "name"},
            {"type": "voice_action", "action": "back", "request_id": "number", "choice_id": "name"}])
        self.assertIsNone(self.coordinator.choices)
        self.assertIsNone(self.coordinator.pending_move)
        self.assertEqual(self.coordinator.pending_navigation.request_id, "number")
        self.native_event("action", source="voice", action="back", request_id="number")
        self.assertIsNone(self.coordinator.pending_navigation)
        self.assertEqual(self.native[-1]["message"], "Back navigation sent.")

    def test_tab_navigation_clears_choices_before_sending_the_bound_direction(self):
        for action in ("tab_left", "tab_right"):
            with self.subTest(action=action):
                self.setUp()
                self.create_choices()
                self.choose()
                self.worker_event("navigation", request_id="number", action=action)
                commands = [command for command in self.native if command["type"] in ("clear_choices", "voice_action")]
                self.assertEqual(commands, [
                    {"type": "clear_choices", "choice_id": "name"},
                    {"type": "voice_action", "action": action, "request_id": "number", "choice_id": "name"}])
                self.assertIsNone(self.coordinator.choices)
                self.assertIsNone(self.coordinator.pending_move)
                self.assertEqual(self.coordinator.pending_navigation.action, action)
                self.native_event("action", source="voice", action="back", request_id="number")
                self.assertIsNotNone(self.coordinator.pending_navigation)
                self.native_event("action", source="voice", action=action, request_id="number")
                self.assertIsNone(self.coordinator.pending_navigation)

    def test_expired_choices_cannot_navigate_from_late_number_transcription(self):
        self.create_choices()
        self.choose()
        self.advance(15)
        self.worker_event("navigation", request_id="number", action="back")
        self.assertEqual(self.commands("voice_action"), [])
        self.assertIsNone(self.coordinator.worker_request)

    def test_choice_expiry_is_rechecked_after_clearing_for_navigation(self):
        self.create_choices()
        self.choose()
        deadline = self.coordinator.choices.expires_at

        def blocked_output(command):
            self.native.append(command)
            if command["type"] == "clear_choices":
                self.now = deadline

        self.coordinator.send_native = blocked_output
        self.worker_event("navigation", request_id="number", action="back")
        self.assertEqual(self.commands("voice_action"), [])

    def test_expiry_is_checked_again_immediately_before_sending_move(self):
        self.create_choices()
        self.choose()
        deadline = self.coordinator.choices.expires_at

        def blocked_output(command):
            self.native.append(command)
            if command["type"] == "clear_choices":
                self.now = deadline

        self.coordinator.send_native = blocked_output
        self.worker_event("selection", request_id="number", target_id="right")
        self.assertIsNone(self.coordinator.choices)
        self.assertEqual(self.commands("voice_action"), [])

    def test_number_response_cannot_create_a_new_ambiguity_set(self):
        self.create_choices()
        self.choose()
        self.worker_event("selection", request_id="number", target_id="right", candidate_ids=[])
        self.assertEqual(self.coordinator.choices.choice_id, "name")
        self.assertEqual(self.commands("voice_action"), [])

    def test_context_cancellation_and_reacquisition_never_revive_old_number(self):
        events = [
            {"type": "state", "armed": False},
            {"type": "action", "source": "gesture", "action": "mission_control"},
            {"type": "choices_cancel", "choice_id": "name"},
        ]
        for event in events:
            with self.subTest(event=event):
                self.setUp()
                self.create_choices()
                self.choose()
                self.coordinator.handle(event, source="native")
                self.native_event("state", armed=True)
                self.point()
                self.worker_event("selection", request_id="number", target_id="right")
                self.assertIsNone(self.coordinator.choices)
                self.assertEqual(self.commands("voice_action"), [])

    def test_hand_loss_and_pinch_intent_preserve_choices_and_deadline(self):
        for event in ({"type": "pointer", "tracked": False},
                      {"type": "gesture_cancel", "source": "gesture"}):
            with self.subTest(event=event):
                self.setUp()
                self.create_choices()
                deadline = self.coordinator.choices.expires_at
                self.coordinator.handle(event, source="native")
                self.assertEqual(self.coordinator.choices.expires_at, deadline)
                self.point()
                self.choose(targets=[])
                self.worker_event("selection", request_id="number", target_id="right")
                self.assertEqual(self.commands("voice_action")[-1]["x"], 650)

    def test_stale_cancel_and_ack_cannot_change_new_choices(self):
        self.create_choices()
        self.native_event("choices_cancel", choice_id="name")
        self.create_choices(key="new", acknowledge=False)
        self.native_event("choices_shown", choice_id="name")
        self.native_event("choices_cancel", choice_id="name")
        self.worker_event("choices_cancel", choice_id="new")
        self.assertEqual(self.coordinator.choices.choice_id, "new")
        self.assertFalse(self.coordinator.choices.acknowledged)
        self.native_event("choices_shown", choice_id="new")
        self.assertTrue(self.coordinator.choices.acknowledged)

    def test_old_worker_selection_cannot_choose_a_new_session(self):
        self.create_choices()
        self.choose()
        self.native_event("choices_cancel", choice_id="name")
        self.worker_event("selection", request_id="number", target_id="right")
        self.create_choices(key="new")
        self.choose(key="new-number")
        self.worker_event("selection", request_id="number", target_id="right")
        self.assertEqual(self.commands("voice_action"), [])
        self.assertEqual(self.coordinator.worker_request, "new-number")
        self.worker_event("selection", request_id="new-number", target_id="left")
        self.assertEqual(self.commands("voice_action")[0]["choice_id"], "new")

    def test_cancelled_followup_keeps_prompt_for_retry(self):
        for invalid in (
                {"type": "targets", "targets": [], "region": {"x": 0, "y": 0, "width": 720, "height": 420}},
                {"type": "error", "message": "Screen capture failed"},
                {"type": "speech_cancel"}):
            with self.subTest(invalid=invalid):
                self.setUp()
                self.create_choices()
                self.native_event("speech_start", request_id="number")
                self.coordinator.handle({**invalid, "request_id": "number"}, source="native")
                self.assertIsNotNone(self.coordinator.choices)
                self.assertEqual(self.commands("voice_action"), [])

    def test_duplicate_capture_cannot_replace_submitted_number_coordinates(self):
        self.create_choices()
        self.choose()
        self.native_event("targets", request_id="number",
                          targets=[dict(target, x=target["x"] + 3) for target in self.targets])
        self.worker_event("selection", request_id="number", target_id="right")
        self.assertEqual(self.commands("voice_action")[0]["x"], 650)


if __name__ == "__main__":
    unittest.main()
