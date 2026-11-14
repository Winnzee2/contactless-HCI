#!/usr/bin/env python3
"""
Main Command Line Interface for Argmax WhisperKit Offline Speech-to-Text.
Provides offline diagnostics, audio file transcription, and live microphone
transcription. Speech is returned as text without interpreting commands.
"""

import argparse
import json
from pathlib import Path
import sys
import time

# Add src to path
sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))

from stt import (
    STTConfig,
    WhisperKitEngine,
    WhisperKitStreamer,
)


def cmd_check(args):
    """Checks whether system is configured for 100% offline speech recognition."""
    print("=" * 65)
    print(" Argmax WhisperKit Offline Environment Check")
    print("=" * 65)

    config = STTConfig(model_name=args.model)
    health = {
        "CLI Binary": config.cli_binary or "NOT FOUND",
        "CLI Installed": "✓ Yes" if config.is_cli_available() else "✗ No (run `brew install whisperkit-cli`)",
        "Model Name": config.model_name,
        "Model Path": str(config.model_path),
        "Model Downloaded": "✓ Yes" if config.is_model_available() else "✗ No (run `bash scripts/setup_models.sh`)",
        "Tokenizer Path": str(config.tokenizer_path),
        "Tokenizer Downloaded": "✓ Yes" if config.is_tokenizer_available() else "✗ No",
        "Network Sandbox": "✓ Available" if Path("/usr/bin/sandbox-exec").is_file() else "✗ Missing (macOS required)",
        "Audio Encoder Compute": config.audio_encoder_compute_units,
        "Text Decoder Compute": config.text_decoder_compute_units,
    }

    for k, v in health.items():
        print(f"  {k:<24}: {v}")

    print("-" * 65)
    if config.is_offline_ready():
        print("  STATUS: [✓] 100% OFFLINE READY")
        print("  Speech-to-text will run completely locally without Wi-Fi.")
    else:
        print("  STATUS: [!] NOT READY FOR OFFLINE USE")
        print("  Please install missing components or run `bash scripts/setup_models.sh`.")
    print("=" * 65)
    return 0 if config.is_offline_ready() else 1


def cmd_transcribe(args):
    """Transcribes an audio file using the local Argmax model."""
    audio_path = Path(args.audio)
    if not audio_path.exists():
        print(f"Error: Audio file does not exist: {audio_path}", file=sys.stderr)
        sys.exit(1)

    config = STTConfig(model_name=args.model)
    engine = WhisperKitEngine(config)

    print(f"Loading local Argmax model: {config.model_name}...", file=sys.stderr)
    t0 = time.perf_counter()
    result = engine.transcribe(audio_path, auto_pad_short_audio=not args.no_pad, detailed=args.detailed)
    wall_sec = time.perf_counter() - t0

    if args.json:
        payload = {
            "text": result.text,
            "audio_duration_sec": result.audio_duration,
            "pipeline_sec": result.pipeline_duration,
            "wall_sec": round(wall_sec, 3),
            "speed_factor": result.speed_factor,
            "model": result.model_name,
            "segments": [
                {"id": s.id, "text": s.text, "start": s.start, "end": s.end}
                for s in result.segments
            ],
        }
        print(json.dumps(payload, indent=2))
    else:
        print("\n" + "=" * 50)
        print(f" TRANSCRIPTION RESULT ({result.model_name})")
        print("=" * 50)
        print(f"Text: \"{result.text}\"\n")
        print(f"Audio Duration : {result.audio_duration:.2f} s")
        print(f"Inference Time : {result.pipeline_duration:.3f} s")
        if result.speed_factor > 0:
            print(f"Speed Factor   : {result.speed_factor:.1f}x real-time")
        print("=" * 50)


def cmd_stream(args):
    """Starts live streaming from the microphone using whisperkit-cli."""
    config = STTConfig(model_name=args.model)

    def on_text(text: str):
        print(f"[Speech] {text}", flush=True)

    def on_partial_text(text: str):
        if text:
            print(f"[Listening] {text}", flush=True)

    print("=" * 60)
    print(" WhisperKit Live Microphone Stream")
    print(f" Model: {config.model_name} (Apple Silicon Neural Engine)")
    print(" Speak into your microphone. Press Ctrl+C to exit.")
    print("=" * 60)

    try:
        with WhisperKitStreamer(config, on_text=on_text,
                                on_partial_text=on_partial_text) as stream:
            while stream.is_running():
                time.sleep(0.1)
            stream.raise_if_failed()
    except KeyboardInterrupt:
        print("\nStopping streaming listener.")


def main():
    parser = argparse.ArgumentParser(
        description="Argmax WhisperKit Offline Speech-to-Text"
    )
    subparsers = parser.add_subparsers(dest="command", help="Subcommand to execute")

    # check
    p_check = subparsers.add_parser("check", help="Check offline setup and model readiness")
    p_check.add_argument("--model", default="tiny.en", help="Model variant to check (default: tiny.en)")

    # transcribe
    p_trans = subparsers.add_parser("transcribe", help="Transcribe an audio file offline")
    p_trans.add_argument("audio", help="Path to audio file (.wav, .m4a, .mp3)")
    p_trans.add_argument("--model", default="tiny.en", help="Model variant (tiny.en or base.en)")
    p_trans.add_argument("--no-pad", action="store_true", help="Disable automatic silence padding for short audio")
    p_trans.add_argument("--detailed", action="store_true", help="Include segment breakdown and timings")
    p_trans.add_argument("--json", action="store_true", help="Output JSON format")

    # stream
    p_stream = subparsers.add_parser("stream", help="Live microphone streaming transcription")
    p_stream.add_argument("--model", default="tiny.en", help="Model variant")

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        sys.exit(0)

    commands = {"check": cmd_check, "transcribe": cmd_transcribe, "stream": cmd_stream}
    try:
        return commands[args.command](args) or 0
    except (OSError, RuntimeError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
