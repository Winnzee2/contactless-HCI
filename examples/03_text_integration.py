#!/usr/bin/env python3
"""Example 03: Hand plain transcript text to another application's event loop.

The speech callback runs on a background reader thread. This example queues its
text and prints it on the main thread. A separate gesture application can use
that same boundary for its text display while owning its own gesture behavior.
"""

from pathlib import Path
from queue import Empty, Queue
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from stt import STTConfig, WhisperKitStreamer


def main():
    transcripts: Queue[str] = Queue()
    print("Receiving plain transcript text. Press Ctrl+C to stop.")
    try:
        with WhisperKitStreamer(STTConfig(model_name="tiny.en"), on_text=transcripts.put) as stream:
            while stream.is_running() or not transcripts.empty():
                try:
                    text = transcripts.get(timeout=0.1)
                except Empty:
                    continue
                # Host/main-thread boundary: display text, without interpreting it.
                print(text, flush=True)
            stream.raise_if_failed()
    except KeyboardInterrupt:
        print("\nText reception stopped.")


if __name__ == "__main__":
    main()
