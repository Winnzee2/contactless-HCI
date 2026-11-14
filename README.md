# Local Contactless HCI: Speech-to-Text with Argmax WhisperKit

> **High-performance, 100% offline speech recognition designed for contactless human-computer interaction, powered exclusively by Argmax CoreML models on Apple Silicon.**

[![Platform](https://img.shields.io/badge/Platform-macOS%20Apple%20Silicon-black?logo=apple)](https://github.com/argmaxinc/WhisperKit)
[![Offline](https://img.shields.io/badge/Offline-No%20Wi--Fi%20Required-success)](#offline-operation)
[![Latency](https://img.shields.io/badge/Latency-~45ms%20per%20command-blue)](#performance-benchmarks)
[![Engine](https://img.shields.io/badge/Model-Argmax%20WhisperKit-orange)](https://github.com/argmaxinc/WhisperKit)

---

## Overview

This repository provides the **Speech-to-Text (STT)** subsystem for a contactless human-computer interaction (HCI) interface. Combining computer vision (hand gesture tracking) with natural voice commands enables touchless control of screens, menus, presentations, and applications.

To ensure **absolute privacy, zero cloud dependency, and instantaneous response times (<50 ms)**, this module runs **exclusively using Argmax Inc.'s WhisperKit CoreML models** directly on the Apple Neural Engine (ANE) without requiring an internet or Wi-Fi connection.

---

## Key Features

* **100% Offline & Private**: Zero external network calls. Runs without Wi-Fi once model weights are stored locally.
* **Argmax WhisperKit CoreML Optimization**: Compiled specifically for Apple Silicon (M1/M2/M3/M4) leveraging the Apple Neural Engine (`cpuAndNeuralEngine`).
* **Ultra-Low Latency (~45 ms)**: Achieves **~22–27x real-time speedup**, transcribing short interactive commands in a fraction of a second.
* **Multimodal Gesture-Voice Fusion**: Built-in `GestureVoiceFusionController` coordinates spatial hand pointing (where to act) with spoken intents (what to do).
* **Gesture-Gated Voice (Push-to-Talk)**: Eliminates false-positive microphone triggers by using gestures (e.g. `PINCH` or `FIST`) to open and close voice listening gates.
* **Contactless Command Parser**: Fuzzy intent matcher for common contactless actions (`SCROLL_UP`, `SCROLL_DOWN`, `ZOOM_IN`, `SELECT`, `CONFIRM`, `INPUT_TEXT`, `SEARCH`).
* **Automatic Silence Padding**: Automatically buffers brief voice commands (<1.5s) to guarantee maximum Whisper recognition accuracy on single-word commands.

---

## Performance Benchmarks

Measured on Apple Silicon (`openai_whisper-tiny.en` on Apple Neural Engine):

| Audio Command | Audio Length | Inference Latency | Speed Factor | Transcribed Text |
| :--- | :--- | :--- | :--- | :--- |
| `select_this_item.wav` | 1.26 s | **46.0 ms** | **27.3x** | *"Select this item."* |
| `confirm_and_proceed.wav`| 1.23 s | **47.8 ms** | **25.8x** | *"Confirm and proceed."* |
| `speech_command.wav` | 1.20 s | **48.1 ms** | **25.0x** | *"Scroll down please."* |
| `open_browser.wav` | 0.91 s | **44.2 ms** | **20.5x** | *"Open Browser."* |
| `zoom_in.wav` | 0.59 s | **43.0 ms** | **13.6x** | *"Zoom in."* |

---

## Project Structure

```
local-AI-argmax/
├── assets/
│   └── samples/                  # Curated audio test samples
│       ├── confirm_and_proceed.wav
│       ├── open_browser.wav
│       ├── select_this_item.wav
│       ├── speech_command.wav
│       └── zoom_in.wav
├── docs/
│   ├── ARCHITECTURE.md           # Multimodal HCI interaction architecture
│   └── OFFLINE_SETUP.md          # Guide on offline verification & compute units
├── examples/
│   ├── 01_transcribe_file.py     # Minimal 5-line transcription example
│   ├── 02_microphone_stream.py   # Real-time microphone listener
│   ├── 03_gesture_voice_fusion.py# Simulated multimodal gesture + voice event loop
│   └── 04_benchmark_offline.py   # Latency and throughput benchmark
├── models/                       # Local CoreML models (Argmax WhisperKit)
│   ├── argmaxinc/
│   │   └── whisperkit-coreml/
│   │       ├── openai_whisper-tiny.en/   # Default fast model (~146 MB)
│   │       └── openai_whisper-base.en/   # Higher accuracy model (~250 MB)
│   └── openai/
│       ├── whisper-tiny.en/              # Tokenizer & vocab
│       └── whisper-base.en/
├── scripts/
│   ├── setup_models.sh           # One-time model setup script
│   └── test_offline.sh           # End-to-end offline verification script
├── src/
│   └── stt/
│       ├── __init__.py           # Package exports
│       ├── audio_utils.py        # 16kHz conversion, padding & PCM tools
│       ├── commands.py           # Contactless HCI action parser
│       ├── config.py             # Model paths & Apple Silicon compute config
│       ├── engine.py             # WhisperKit CoreML inference engine
│       ├── fusion.py             # Gesture + Voice multimodal controller
│       └── stream.py             # Live microphone streaming listener
├── tests/                        # Automated unit & integration tests
│   ├── test_commands.py
│   ├── test_engine.py
│   └── test_fusion.py
├── cli.py                        # Central command-line tool
├── requirements.txt              # Standard library friendly dependencies
└── README.md
```

---

## Quickstart

### 1. Prerequisites (Homebrew)
Install Argmax's WhisperKit CLI:
```bash
brew install whisperkit-cli
```

### 2. Verify Offline Readiness
Run the environment diagnostic check:
```bash
./cli.py check
```
If you see `STATUS: [✓] 100% OFFLINE READY`, you can disconnect Wi-Fi anytime.

### 3. Transcribe an Audio File Offline
```bash
./cli.py transcribe assets/samples/select_this_item.wav
```
Output:
```
==================================================
 TRANSCRIPTION RESULT (openai_whisper-tiny.en)
==================================================
Text: "Select this item."

Audio Duration : 1.26 s
Inference Time : 0.046 s
Speed Factor   : 27.3x real-time
==================================================
```

### 4. Interactive Command Parser Test
Test how natural phrases map to touchless actions:
```bash
./cli.py commands
```

### 5. Multimodal Gesture + Voice Demo
See spatial pointing coordinates fuse with speech intents in real time:
```bash
./cli.py demo
```

### 6. Live Microphone Streaming
Transcribe your voice continuously from your Mac microphone:
```bash
./cli.py stream
```

---

## Python API Usage

### Transcribing an Audio File
```python
from stt import STTConfig, WhisperKitEngine

# Configure for local Apple Neural Engine execution
config = STTConfig(model_name="tiny.en")
engine = WhisperKitEngine(config)

# Transcribe
result = engine.transcribe("path/to/voice_command.wav")
print(f"Recognized: {result.text}")
print(f"Latency: {result.pipeline_duration * 1000:.1f} ms")
```

### Parsing Spoken Commands for Touchless Control
```python
from stt import ContactlessCommandParser

parser = ContactlessCommandParser()

# Natural speech with filler words
cmd = parser.parse("could you please scroll down")
print(cmd.action)  # ContactlessAction.SCROLL_DOWN

# Parameterized dictation
cmd = parser.parse("type contactless interaction")
print(cmd.action)     # ContactlessAction.INPUT_TEXT
print(cmd.parameter)  # "contactless interaction"
```

---

## Integrating with Hand Gesture Detection (OpenCV / MediaPipe)

In a contactless HCI application, your vision pipeline detects hand landmarks while `GestureVoiceFusionController` unifies them:

```python
from stt import (
    ContactlessAction,
    ContactlessCommandParser,
    GestureEvent,
    GestureVoiceFusionController,
    HandGesture,
)

# 1. Initialize fusion controller
def on_fused_action(action):
    print(f"DISPATCH UI EVENT: {action.action.value} at coords {action.coordinates}")

fusion = GestureVoiceFusionController(on_action=on_fused_action)

# 2. In your OpenCV / MediaPipe hand tracking loop:
# When index finger pointing is detected:
fusion.handle_gesture(
    GestureEvent(
        gesture=HandGesture.POINT,
        x=normalized_x,  # 0.0 to 1.0 screen coordinate
        y=normalized_y,
    )
)

# 3. When WhisperKit detects speech:
# "Select this" automatically fuses with the pointing coordinates!
fusion.handle_voice_transcript("select this please")
```

---

## Testing

Run the full unit and integration test suite:

```bash
python3 -m unittest discover tests
```

Or run the offline verification script:
```bash
bash scripts/test_offline.sh
```

---

## License

MIT License. WhisperKit models and tools are developed by [Argmax Inc.](https://github.com/argmaxinc/WhisperKit).
