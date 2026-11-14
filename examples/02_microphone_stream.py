#!/usr/bin/env python3
"""
Example 02: Real-time Live Microphone Streaming with Argmax WhisperKit.
Captures microphone audio locally and prints recognized contactless voice commands.
"""

from pathlib import Path
import sys
import time

# Ensure src is importable
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from stt import ContactlessCommandParser, STTConfig, WhisperKitStreamer


def on_speech(raw_text: str):
    print(f"[Live Voice] \"{raw_text}\"")


def on_action(cmd):
    print(f"  ==> ACTION DETECTED: {cmd.action.value} (Confidence: {cmd.confidence:.2f})")
    if cmd.parameter:
        print(f"      Parameter: {cmd.parameter}")


def main():
    config = STTConfig(model_name="tiny.en")
    parser = ContactlessCommandParser()

    print("=" * 60)
    print(" Live Microphone Stream (Argmax WhisperKit on-device)")
    print(" Try saying: 'scroll down', 'zoom in', 'select this', 'type hello'")
    print(" Press Ctrl+C to stop.")
    print("=" * 60)

    try:
        with WhisperKitStreamer(config, parser=parser, on_text=on_speech, on_command=on_action):
            while True:
                time.sleep(0.5)
    except KeyboardInterrupt:
        print("\nStreaming listener stopped.")


if __name__ == "__main__":
    main()
