#!/usr/bin/env python3
"""
Example 03: Multimodal Contactless HCI Interaction (Gesture + Voice Fusion).
Demonstrates how vision-based hand gestures (pointing coordinates, push-to-talk triggers)
fuse with Argmax WhisperKit speech-to-text in a unified event loop.
"""

from pathlib import Path
import random
import sys
import time

# Ensure src is importable
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from stt import (
    ContactlessAction,
    ContactlessCommandParser,
    FusedHCIAction,
    GestureEvent,
    GestureVoiceFusionController,
    HandGesture,
    STTConfig,
    WhisperKitEngine,
)


def render_ui_screen(fused_action: FusedHCIAction):
    """Simulated rendering of contactless HCI user interface response."""
    print("\n" + "-" * 55)
    print(f"  [TOUCHLESS UI EVENT] {fused_action.action.value}")
    print(f"  Source Mode        : {fused_action.source}")
    if fused_action.coordinates:
        x, y = fused_action.coordinates
        print(f"  Spatial Target (X,Y): ({x:.2f}, {y:.2f})")
    if fused_action.parameter:
        print(f"  Payload Parameter  : \"{fused_action.parameter}\"")
    print("-" * 55)


def main():
    config = STTConfig(model_name="tiny.en")
    parser = ContactlessCommandParser()
    fusion = GestureVoiceFusionController(parser=parser, on_action=render_ui_screen)

    print("=" * 65)
    print(" Multimodal Contactless HCI Loop (Gesture + WhisperKit Voice)")
    print(" Running 100% locally on Apple Silicon without Wi-Fi")
    print("=" * 65)

    # Simulated multimodal user interaction stream:
    events = [
        # 1. Pointing at an onscreen card + saying 'Select this'
        (
            GestureEvent(gesture=HandGesture.POINT, x=0.75, y=0.20),
            "select this item please",
            "User points at item on top-right and says 'select this item please'",
        ),
        # 2. Hand swipe gesture alone
        (
            GestureEvent(gesture=HandGesture.SWIPE_LEFT, x=0.50, y=0.50),
            None,
            "User performs quick swipe left to go back",
        ),
        # 3. Pure voice command: 'scroll down'
        (
            None,
            "scroll down",
            "User says 'scroll down' while hands are at rest",
        ),
        # 4. Pointing at search bar + dictating query
        (
            GestureEvent(gesture=HandGesture.POINT, x=0.20, y=0.10),
            "search local machine learning models",
            "User points at search bar and says 'search local machine learning models'",
        ),
        # 5. Thumbs up gesture to confirm dialog
        (
            GestureEvent(gesture=HandGesture.THUMBS_UP, x=0.50, y=0.50),
            None,
            "User confirms modal dialog with a thumbs up gesture",
        ),
    ]

    for gesture, voice_text, description in events:
        print(f"\n>>> Scenario: {description}")
        time.sleep(0.8)

        if gesture:
            print(f"  [Vision Detector] Hand gesture detected: {gesture.gesture.value} at ({gesture.x:.2f}, {gesture.y:.2f})")
            fusion.handle_gesture(gesture)

        if voice_text:
            print(f"  [WhisperKit STT] Audio transcribed: \"{voice_text}\"")
            fusion.handle_voice_transcript(voice_text)

    print("\n" + "=" * 65)
    print(" Demonstration finished.")
    print("=" * 65)


if __name__ == "__main__":
    main()
