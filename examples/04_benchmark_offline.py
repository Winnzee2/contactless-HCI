#!/usr/bin/env python3
"""
Example 04: Offline Latency & Throughput Benchmark.
Benchmarks local WhisperKit inference across sample audio files, measuring
audio duration, pipeline latency, and real-time speed factors.
"""

from pathlib import Path
import sys

# Ensure src is importable
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from stt import STTConfig, WhisperKitEngine


def main():
    samples_dir = Path(__file__).resolve().parent.parent / "assets" / "samples"
    wav_files = sorted(list(samples_dir.glob("*.wav")))

    if not wav_files:
        print(f"No WAV files found in {samples_dir}")
        return

    print("=" * 75)
    print(" Argmax WhisperKit Offline Performance Benchmark")
    print(" Architecture: Apple Silicon Neural Engine + CoreML")
    print("=" * 75)

    config = STTConfig(model_name="tiny.en")
    print(f"Model: {config.model_name}")
    engine = WhisperKitEngine(config)

    print("\n" + "-" * 75)
    print(f"{'Audio File':<26} | {'Audio Len':<10} | {'Latency':<10} | {'Speedup':<10} | {'Transcript'}")
    print("-" * 75)

    total_audio = 0.0
    total_time = 0.0

    for wav in wav_files:
        res = engine.transcribe(wav, detailed=True)
        total_audio += res.audio_duration
        total_time += res.pipeline_duration

        speedup_str = f"{res.speed_factor:.1f}x" if res.speed_factor > 0 else "N/A"
        print(
            f"{wav.name:<26} | "
            f"{res.audio_duration:<9.2f}s | "
            f"{res.pipeline_duration * 1000:<8.1f}ms | "
            f"{speedup_str:<10} | "
            f"\"{res.text}\""
        )

    print("-" * 75)
    avg_speedup = total_audio / total_time if total_time > 0 else 0.0
    print(f"Total Audio Processed: {total_audio:.2f} s")
    print(f"Total Inference Time : {total_time:.3f} s")
    print(f"Average Speedup Factor: {avg_speedup:.1f}x real-time")
    print("=" * 75)


if __name__ == "__main__":
    main()
