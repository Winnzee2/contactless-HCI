#!/usr/bin/env python3
"""
Main Command Line Interface for Argmax WhisperKit Offline Speech-to-Text.
Provides offline diagnostics, audio transcription, live streaming,
command parsing, and multimodal contactless HCI demonstrations.
"""

import argparse
import json
from pathlib import Path
import sys
import time

# Add src to path
sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))

from stt import (
    ContactlessAction,
    ContactlessCommandParser,
    GestureEvent,
    GestureVoiceFusionController,
    HandGesture,
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


def cmd_transcribe(args):
    """Transcribes an audio file using the local Argmax model."""
    audio_path = Path(args.audio)
    if not audio_path.exists():
        print(f"Error: Audio file does not exist: {audio_path}", file=sys.stderr)
        sys.exit(1)

    config = STTConfig(model_name=args.model)
    engine = WhisperKitEngine(config)

    print(f"Loading local Argmax model: {config.model_name}...")
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


def cmd_commands(args):
    """Tests the contactless voice command parser."""
    parser = ContactlessCommandParser()
    print("=" * 60)
    print(" Contactless HCI Voice Command Parser")
    print(" Type a phrase (e.g. 'scroll down please', 'type hello world')")
    print(" Type 'quit' or 'exit' to stop.")
    print("=" * 60)

    test_phrases = [
        "scroll down please",
        "select this item",
        "zoom in",
        "confirm and proceed",
        "type my name is alex",
        "search local ai models",
        "go back",
    ]

    print("\nDemonstration matches:")
    for phrase in test_phrases:
        parsed = parser.parse(phrase)
        print(f"  Input: '{phrase}' -> {parsed}")

    print("\nInteractive mode:")
    while True:
        try:
            line = input("\nVoice Input > ").strip()
        except (EOFError, KeyboardInterrupt):
            break
        if not line or line.lower() in ("quit", "exit"):
            break
        parsed = parser.parse(line)
        print(f"Parsed Command: {parsed}")


def cmd_stream(args):
    """Starts live streaming from the microphone using whisperkit-cli."""
    config = STTConfig(model_name=args.model)
    parser = ContactlessCommandParser()

    def on_text(text: str):
        print(f"[Speech] {text}")

    def on_command(cmd):
        print(f"  >>> ACTION TRIGGERED: {cmd}")

    print("=" * 60)
    print(" WhisperKit Live Microphone Stream")
    print(f" Model: {config.model_name} (Apple Silicon Neural Engine)")
    print(" Speak into your microphone. Press Ctrl+C to exit.")
    print("=" * 60)

    try:
        with WhisperKitStreamer(config, parser=parser, on_text=on_text, on_command=on_command):
            while True:
                time.sleep(0.5)
    except KeyboardInterrupt:
        print("\nStopping streaming listener.")


def cmd_demo(args):
    """Runs a simulated contactless multimodal interaction loop (Gesture + Voice)."""
    parser = ContactlessCommandParser()
    fusion = GestureVoiceFusionController(parser=parser)

    def on_action(action):
        print(f"  ==> HCI EVENT DISPATCHED: {action}")

    fusion.on_action = on_action

    print("=" * 65)
    print(" Contactless HCI Multimodal Simulation (Gesture + Voice)")
    print(" Demonstrating spatial pointing + speech deictic resolution")
    print("=" * 65)

    scenarios = [
        {
            "desc": "1. User points index finger at top-right card (x=0.82, y=0.15) and speaks 'Select this'",
            "gesture": GestureEvent(gesture=HandGesture.POINT, x=0.82, y=0.15),
            "voice": "select this please",
        },
        {
            "desc": "2. User pinches to activate push-to-talk voice gate, then speaks 'Zoom in'",
            "gesture": GestureEvent(gesture=HandGesture.PINCH, x=0.50, y=0.50),
            "voice": "zoom in",
        },
        {
            "desc": "3. User gives THUMBS_UP gesture to approve a confirmation modal",
            "gesture": GestureEvent(gesture=HandGesture.THUMBS_UP, x=0.50, y=0.50),
            "voice": None,
        },
        {
            "desc": "4. User points at text box and dictates 'type contactless interaction'",
            "gesture": GestureEvent(gesture=HandGesture.POINT, x=0.35, y=0.60),
            "voice": "type contactless interaction",
        },
        {
            "desc": "5. User speaks navigation command 'scroll down'",
            "gesture": None,
            "voice": "scroll down",
        },
    ]

    for item in scenarios:
        print(f"\n{item['desc']}")
        time.sleep(0.6)
        if item["gesture"]:
            print(f"  [Hand Gesture Event] {item['gesture'].gesture.value} at ({item['gesture'].x:.2f}, {item['gesture'].y:.2f})")
            fusion.handle_gesture(item["gesture"])
        if item["voice"]:
            print(f"  [WhisperKit Speech]  \"{item['voice']}\"")
            fusion.handle_voice_transcript(item["voice"])

    print("\n" + "=" * 65)
    print(" Simulation complete. All actions resolved locally without network!")
    print("=" * 65)


def main():
    parser = argparse.ArgumentParser(
        description="Argmax WhisperKit Offline Speech-to-Text for Contactless HCI"
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

    # commands
    subparsers.add_parser("commands", help="Interactive contactless voice command parser")

    # stream
    p_stream = subparsers.add_parser("stream", help="Live microphone streaming transcription")
    p_stream.add_argument("--model", default="tiny.en", help="Model variant")

    # demo
    subparsers.add_parser("demo", help="Demonstrate multimodal gesture + voice fusion")

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        sys.exit(0)

    if args.command == "check":
        cmd_check(args)
    elif args.command == "transcribe":
        cmd_transcribe(args)
    elif args.command == "commands":
        cmd_commands(args)
    elif args.command == "stream":
        cmd_stream(args)
    elif args.command == "demo":
        cmd_demo(args)


if __name__ == "__main__":
    main()
