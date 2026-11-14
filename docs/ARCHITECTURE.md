# Speech-to-text architecture

This package has one responsibility: convert audio to text with local Argmax WhisperKit inference. It does not parse spoken commands, classify gestures, combine gestures with speech, or invoke application actions.

## Data flow

```text
Audio file or PCM bytes → WhisperKitEngine → TranscriptionResult.text
Microphone             → WhisperKitStreamer → Confirmed/partial text
```

`WhisperKitEngine` returns text, segments, and timing metadata. `WhisperKitStreamer` exposes confirmed strings through `on_text` and `get_text(timeout)`, plus provisional strings through `on_partial_text` for display. Words such as “select,” “scroll,” and “confirm” remain ordinary transcript content.

## Components

| Module | Responsibility |
| --- | --- |
| `stt.config` | Resolve local model/tokenizer paths and validate required assets |
| `stt.runtime` | Build local Argmax invocations with networking denied |
| `stt.engine` | Transcribe files or audio buffers and parse structured results |
| `stt.stream` | Read microphone transcript snapshots and emit new text |
| `stt.audio_utils` | Inspect, convert, pad, and write audio |

Model setup is explicit and separate from inference. Only `scripts/setup_models.py` downloads model assets. Missing runtime assets produce an error rather than an automatic download.

## Integrating with a separate gesture program

A host application can run the speech module alongside a gesture recognizer:

```text
Speech audio → This package → Plain transcript text → Host application's text display
Hand motion  → Separate gesture program             → Host application's behavior
```

The host decides where text belongs. For example, a gesture can select a text field, and the host can place received transcript text into that field. That selection and insertion behavior belongs to the host; this package supplies text only.

If both systems use Python, import `stt` in the host application. Use `get_text(timeout)` from its event loop, or have `on_text` put strings into a thread-safe queue consumed on the UI/main thread. `examples/03_text_integration.py` demonstrates the callback approach without performing any gesture or application action.

Callbacks run on the background stream-reader thread, so they should return quickly. Avoid manipulating a UI directly from a callback. Provisional text can be replaced as recognition improves; use confirmed text when appending to a document or transcript. Choose one confirmed-text delivery method per consumer to avoid duplicate display.

If the programs must remain separate processes or use different languages, the host can bridge transcript strings through local operating-system pipes. The bridge belongs in the Python/host layer, outside the Argmax inference subprocess. This requires no Wi-Fi or external server.

## Offline boundary

Argmax runs with explicit local model and tokenizer paths under a macOS sandbox policy denying network access. Models, tokenizers, and the CLI must be prepared beforehand. To install on a machine that never connects to the internet, transfer the required installed runtime and compatible assets from a prepared machine.

The gesture program must likewise have its models and dependencies locally available. Test the combined host application from a fresh launch with networking disabled. Local transcription cannot make an inherently online application feature work offline.
