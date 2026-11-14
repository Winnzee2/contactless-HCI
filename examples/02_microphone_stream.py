#!/usr/bin/env python3
"""Example 02: Print local microphone transcription as plain text."""

from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from stt import STTConfig, WhisperKitStreamer


def on_speech(text: str):
    print(f"[Speech] {text}", flush=True)


def on_partial_text(text: str):
    if text:
        print(f"[Listening] {text}", flush=True)


def main():
    config = STTConfig(model_name="tiny.en")
    print("Local microphone transcription. Speak naturally; press Ctrl+C to stop.")
    try:
        with WhisperKitStreamer(config, on_text=on_speech, on_partial_text=on_partial_text) as stream:
            while stream.is_running():
                time.sleep(0.1)
            stream.raise_if_failed()
    except KeyboardInterrupt:
        print("\nMicrophone transcription stopped.")


if __name__ == "__main__":
    main()
