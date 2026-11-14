#!/usr/bin/env python3
"""
Main application entry point for Local Contactless HCI (Argmax WhisperKit STT).
Runs local offline speech recognition, contactless command parsing,
and multimodal gesture-voice interaction.
"""

from pathlib import Path
import sys
import time

# Ensure src is in python path
sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))

from stt import (
    ContactlessAction,
    ContactlessCommandParser,
    FusedHCIAction,
    GestureEvent,
    GestureVoiceFusionController,
    HandGesture,
    STTConfig,
    WhisperKitEngine,
    WhisperKitStreamer,
)


def print_header():
    print("=" * 68)
    print("   LOCAL CONTACTLESS HCI: ARGMAX WHISPERKIT SPEECH-TO-TEXT")
    print("   100% Offline • Apple Silicon Neural Engine • Zero Cloud Dependency")
    print("=" * 68)


def run_full_pipeline_demo():
    """Runs a complete end-to-end demonstration of the offline STT and fusion engine."""
    config = STTConfig(model_name="tiny.en")
    print(f"\n[1/3] Checking Offline Environment...")
    if not config.is_offline_ready():
        print("  [!] Offline environment is missing components.")
        print("      Run `bash scripts/setup_models.sh` to download models.")
        return 1

    print("  [✓] System is 100% OFFLINE READY.")
    print(f"  [✓] Loaded model: {config.model_name}")
    print(f"  [✓] Compute units: Encoder={config.audio_encoder_compute_units}, Decoder={config.text_decoder_compute_units}")

    print("\n[2/3] Initializing Argmax CoreML WhisperKit Engine...")
    t0 = time.perf_counter()
    engine = WhisperKitEngine(config)
    print(f"  [✓] Model ready in {(time.perf_counter() - t0) * 1000:.1f} ms.")

    parser = ContactlessCommandParser()
    fusion = GestureVoiceFusionController(parser=parser)

    def on_ui_action(action: FusedHCIAction):
        coords = f" at ({action.coordinates[0]:.2f}, {action.coordinates[1]:.2f})" if action.coordinates else ""
        param = f" -> \"{action.parameter}\"" if action.parameter else ""
        print(f"       ==> DISPATCH TOUCHLESS ACTION: [{action.action.value}]{param}{coords} (via {action.source})")

    fusion.on_action = on_ui_action

    print("\n[3/3] Running End-to-End Multimodal Contactless Pipeline...")
    samples_dir = Path(__file__).resolve().parent / "assets" / "samples"
    test_cases = [
        {
            "audio": samples_dir / "select_this_item.wav",
            "gesture": GestureEvent(gesture=HandGesture.POINT, x=0.78, y=0.22),
            "scenario": "User points index finger at an onscreen item and speaks command",
        },
        {
            "audio": samples_dir / "confirm_and_proceed.wav",
            "gesture": GestureEvent(gesture=HandGesture.THUMBS_UP, x=0.50, y=0.50),
            "scenario": "User gives thumbs up and speaks confirmation",
        },
        {
            "audio": samples_dir / "speech_command.wav",
            "gesture": None,
            "scenario": "User speaks hands-free navigation command",
        },
        {
            "audio": samples_dir / "zoom_in.wav",
            "gesture": GestureEvent(gesture=HandGesture.POINT, x=0.50, y=0.50),
            "scenario": "User points at center image and commands zoom",
        },
    ]

    for i, case in enumerate(test_cases, 1):
        print(f"\n  --- Interaction #{i}: {case['scenario']} ---")
        if case["gesture"]:
            g = case["gesture"]
            print(f"    [Vision Tracker] Gesture: {g.gesture.value} at screen coordinate ({g.x:.2f}, {g.y:.2f})")
            fusion.handle_gesture(g)

        if case["audio"].exists():
            # Actual offline CoreML transcription on Apple Silicon Neural Engine
            res = engine.transcribe(case["audio"], detailed=True)
            print(f"    [WhisperKit STT] Transcribed \"{res.text}\" (took {res.pipeline_duration * 1000:.1f} ms, {res.speed_factor:.1f}x real-time)")
            fusion.handle_voice_transcript(res.text)

    print("\n" + "=" * 68)
    print("   DEMONSTRATION COMPLETE: ALL INFERENCE RUN LOCALLY WITHOUT WI-FI")
    print("=" * 68)
    print("\nNext steps:")
    print("  • To stream from your live microphone:  python3 cli.py stream")
    print("  • To transcribe a custom audio file:   python3 cli.py transcribe <path.wav>")
    print("  • To test the command parser:          python3 cli.py commands")
    print("  • To run performance benchmarks:       python3 examples/04_benchmark_offline.py\n")
    return 0


if __name__ == "__main__":
    print_header()
    # If args passed, delegate to cli.main()
    if len(sys.argv) > 1:
        from cli import main as cli_main
        cli_main()
    else:
        sys.exit(run_full_pipeline_demo())
