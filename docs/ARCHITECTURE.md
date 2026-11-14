# Multimodal Contactless Human-Computer Interaction (HCI) Architecture

This document describes the system architecture for contactless human-computer interaction combining **Vision-Based Hand Gesture Recognition** and **On-Device Speech-to-Text via Argmax WhisperKit**.

---

## 1. High-Level Architecture

```
                   +---------------------------+
                   |     Contactless User      |
                   +-------------+-------------+
                                 |
            +--------------------+--------------------+
            | (Physical Hand Motion)                  | (Acoustic Speech)
            v                                         v
   +-------------------+                     +-------------------+
   |   Vision Sensor   |                     |    Microphone     |
   | (Webcam / Camera) |                     |  (Built-in / USB) |
   +---------+---------+                     +---------+---------+
             |                                         |
             v                                         v
   +-------------------+                     +-------------------+
   |  Gesture Detector |                     | WhisperKit Engine |
   | (MediaPipe/OpenCV)|                     |  (Argmax CoreML)  |
   |                   |                     |  Neural Engine    |
   +---------+---------+                     +---------+---------+
             |                                         |
             | GestureEvent                            | Transcript
             | (Pointing, Pinch, ThumbsUp)             | ("Select this", "Scroll down")
             |                                         |
             +--------------------+--------------------+
                                  |
                                  v
                +-----------------------------------+
                |   Multimodal Fusion Controller    |
                |  (GestureVoiceFusionController)   |
                +-----------------+-----------------+
                                  |
                                  | Fused HCI Action
                                  v
                +-----------------------------------+
                | Contactless Application UI / OS   |
                |  (Scroll, Click, Zoom, Dictate)   |
                +-----------------------------------+
```

---

## 2. The Core Interaction Challenges & Solutions

### A. The "Midas Touch" & False-Positive Problem
In contactless systems, microphones that are always actively listening will inadvertently capture room chatter, background television, or casual comments.

* **Solution: Gesture-Gated Push-to-Talk (PTT)**
  * The user performs a distinct hand gesture (e.g., `PINCH` or `FIST`) to open the voice window.
  * Releasing the gesture (`OPEN_PALM` or hand removal) closes the window and immediately triggers offline transcription.
  * This guarantees voice commands are only processed when the user explicitly intends to communicate.

### B. The Deictic "This / Here" Problem
Spoken commands like *"Click this"* or *"Open that"* are semantically incomplete without spatial context. Conversely, hand pointing is spatially precise but lacks semantic granularity (is pointing meant to hover, select, copy, or delete?).

* **Solution: Spatiotemporal Fusion**
  * When a voice command containing deictic words (*"this"*, *"here"*, *"select"*) is recognized, the `GestureVoiceFusionController` queries the most recent hand pointer coordinates $(x, y)$ registered within a 2-second time window.
  * The resulting `FusedHCIAction` pairs the semantic intent (`SELECT`) with exact screen coordinates $(x, y)$.

### C. Offline Latency Requirements
Contactless interactions feel clunky if UI responses take several seconds.

* **Solution: Argmax WhisperKit on Apple Silicon Neural Engine**
  * By compiling Whisper directly to Apple CoreML `.mlmodelc` targeting the Apple Neural Engine (`cpuAndNeuralEngine`), inference executes in **~45 ms** for typical 1-2 second voice commands.
  * This achieves a **~25x real-time speedup** with zero cloud latency and zero Wi-Fi dependencies.

---

## 3. Component Breakdown

| Module | Responsibility | Key Classes |
| :--- | :--- | :--- |
| `stt.engine` | CoreML inference execution using `whisperkit-cli` | `WhisperKitEngine`, `TranscriptionResult` |
| `stt.config` | Manages local paths, compute units, offline checks | `STTConfig` |
| `stt.commands` | Natural speech parser & contactless intent mapper | `ContactlessCommandParser`, `ContactlessAction` |
| `stt.stream` | Real-time continuous microphone listener | `WhisperKitStreamer` |
| `stt.fusion` | Multimodal bridge connecting vision & voice | `GestureVoiceFusionController`, `FusedHCIAction` |
| `stt.audio_utils` | Audio format validation, silence padding & PCM tools | `pad_audio_with_silence`, `get_audio_info` |

---

## 4. Multimodal Fusion Matrix

| Gesture Input | Voice Input | Fused Action Dispatched | Description |
| :--- | :--- | :--- | :--- |
| `POINT(x, y)` | *"Select this"* | `SELECT` at `(x, y)` | Spatial deictic selection |
| `POINT(x, y)` | *"Zoom in here"* | `ZOOM_IN` at `(x, y)` | Focal magnification |
| `PINCH` (held) | *"Scroll down"* | `SCROLL_DOWN` | Gesture-gated navigation |
| `POINT(x, y)` | *"Type hello"* | `INPUT_TEXT("hello")` at `(x, y)` | Dictation directed into input box |
| `THUMBS_UP` | *(None)* | `CONFIRM` | Pure gesture approval |
| `OPEN_PALM` | *(None)* | `CANCEL` / Release | Pure gesture stop |
| *(None)* | *"Go home"* | `GO_HOME` | Voice-only navigation |
