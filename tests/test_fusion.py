"""
Unit tests for GestureVoiceFusionController.
"""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from stt.commands import ContactlessAction, ContactlessCommandParser
from stt.fusion import (
    FusedHCIAction,
    GestureEvent,
    GestureVoiceFusionController,
    HandGesture,
)


class TestGestureVoiceFusion(unittest.TestCase):
    def setUp(self):
        self.dispatched: list[FusedHCIAction] = []
        self.parser = ContactlessCommandParser()
        self.fusion = GestureVoiceFusionController(
            parser=self.parser,
            on_action=lambda a: self.dispatched.append(a),
        )

    def test_pure_gesture_action(self):
        gesture = GestureEvent(gesture=HandGesture.THUMBS_UP, x=0.5, y=0.5)
        action = self.fusion.handle_gesture(gesture)

        self.assertIsNotNone(action)
        self.assertEqual(action.action, ContactlessAction.CONFIRM)
        self.assertEqual(action.source, "GESTURE")
        self.assertEqual(action.coordinates, (0.5, 0.5))

    def test_deictic_point_and_speak_fusion(self):
        # 1. Point at top-left button (x=0.15, y=0.20)
        gesture = GestureEvent(gesture=HandGesture.POINT, x=0.15, y=0.20)
        self.fusion.handle_gesture(gesture)

        # 2. Say "Select this"
        action = self.fusion.handle_voice_transcript("select this please")

        self.assertIsNotNone(action)
        self.assertEqual(action.action, ContactlessAction.SELECT)
        self.assertEqual(action.source, "FUSED")
        self.assertEqual(action.coordinates, (0.15, 0.20))

    def test_pure_voice_action(self):
        # Reset gesture context
        self.fusion.last_gesture_event = None

        action = self.fusion.handle_voice_transcript("scroll down")
        self.assertEqual(action.action, ContactlessAction.SCROLL_DOWN)
        self.assertEqual(action.source, "VOICE")
        self.assertIsNone(action.coordinates)

    def test_push_to_talk_gate(self):
        self.assertFalse(self.fusion.is_voice_gate_active)

        # Pinch gesture starts voice gate
        self.fusion.handle_gesture(GestureEvent(gesture=HandGesture.PINCH))
        self.assertTrue(self.fusion.is_voice_gate_active)

        # Release hand stops voice gate
        self.fusion.handle_gesture(GestureEvent(gesture=HandGesture.OPEN_PALM))
        self.assertFalse(self.fusion.is_voice_gate_active)


if __name__ == "__main__":
    unittest.main()
