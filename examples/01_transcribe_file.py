#!/usr/bin/env python3
"""
Example 01: Offline File Transcription with Argmax WhisperKit.
Demonstrates loading the local CoreML model and transcribing an audio file in ~50ms.
"""

from pathlib import Path
import sys

# Ensure src is importable
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from stt import STTConfig, WhisperKitEngine


def main():
    # 1. Initialize configuration (defaults to tiny.en on Apple Silicon Neural Engine)
    config = STTConfig(model_name="tiny.en")

    # 2. Initialize offline engine
    print(f"Loading local Argmax WhisperKit model: {config.model_name}...")
    engine = WhisperKitEngine(config)

    # 3. Transcribe sample audio
    sample_path = Path(__file__).resolve().parent.parent / "assets" / "samples" / "select_this_item.wav"
    print(f"Transcribing audio file: {sample_path.name}")

    result = engine.transcribe(sample_path)

    print("\n" + "=" * 45)
    print(f"Recognized Speech: \"{result.text}\"")
    print(f"Audio Duration   : {result.audio_duration:.2f} s")
    print(f"Inference Latency: {result.pipeline_duration * 1000:.1f} ms")
    print(f"Speed Factor     : {result.speed_factor:.1f}x real-time")
    print("=" * 45)


if __name__ == "__main__":
    main()
