# Offline Speech-to-Text with Argmax WhisperKit

This project converts audio into text locally on an Apple Silicon Mac using Argmax WhisperKit. It supports audio files, audio byte buffers, and live microphone transcription.

**Speech is text only.** Saying “scroll down,” “select this,” or “open browser” produces those words as a transcript. The speech module does not interpret them as commands, recognize gestures, or perform application actions. A separate hand-gesture program can own those functions.

After one-time setup, inference uses local CoreML models and tokenizers. File and microphone inference run with network access denied by a macOS sandbox policy, so they work without Wi-Fi.

## Setup

Requires Apple Silicon, macOS 14+, Python 3.9+, and Homebrew. While online:

```bash
brew install whisperkit-cli
bash scripts/setup_models.sh
```

The default model is `tiny.en` for English speech. To prepare the larger English model, use `bash scripts/setup_models.sh --model base.en`; use `--model all` to prepare both. Setup verifies a sample transcription with networking denied before reporting success.

```bash
python3 cli.py check
```

This checks required local assets and exits nonzero if anything is missing. See [the offline setup guide](docs/OFFLINE_SETUP.md) for storage layout and troubleshooting.

## Use

Transcribe a local recording:

```bash
python3 cli.py transcribe assets/samples/select_this_item.wav
python3 cli.py transcribe recording.m4a --model base.en --json
```

Transcribe microphone audio:

```bash
python3 cli.py stream
```

Allow microphone access for the terminal or hosting app when macOS prompts. `[Listening]` lines are provisional and may change; `[Speech]` lines are newly confirmed transcript segments. Confirmation can lag behind speech. Ctrl+C stops capture and discards unconfirmed text.

`python3 main.py` displays the same CLI help. Its available subcommands are `check`, `transcribe`, and `stream`.

## Python API

Run your script with `PYTHONPATH=src python3 your_script.py` from the project root, or use the runnable examples below.

```python
from stt import STTConfig, WhisperKitEngine

engine = WhisperKitEngine(STTConfig(model_name="tiny.en"))
result = engine.transcribe("recording.wav")
print(result.text)
```

For audio already captured by another local application:

```python
# pcm_bytes contains mono 16-bit PCM at 16 kHz.
result = engine.transcribe_bytes(pcm_bytes, is_raw_pcm=True, sample_rate=16000)
transcript = result.text
```

For continuous microphone input, poll confirmed text from the stream's queue:

```python
from stt import STTConfig, WhisperKitStreamer

try:
    with WhisperKitStreamer(STTConfig(model_name="tiny.en")) as stream:
        while stream.is_running():
            text = stream.get_text(timeout=0.1)
            if text is not None:
                print(text)
        stream.raise_if_failed()
        # Drain any confirmed text queued immediately before the stream ended.
        while (text := stream.get_text(timeout=0)) is not None:
            print(text)
except KeyboardInterrupt:
    pass
```

Alternatively, pass `on_text=callback` for newly confirmed text and `on_partial_text=callback` for provisional display text. Callbacks run on the stream's background reader thread; keep them short and use a thread-safe queue to hand text to a UI/main thread. Choose either queue polling or callbacks for consuming confirmed text so your application does not display it twice.

## Connect to a separate gesture application

The integration boundary is a string. Your gesture application can receive transcript text for display or text entry while retaining ownership of gesture recognition and application behavior. No gesture types, action dispatchers, or voice command mappings are provided by this package.

See [examples/03_text_integration.py](examples/03_text_integration.py) for a callback-to-queue integration. Both applications can communicate entirely on-device; see [the architecture notes](docs/ARCHITECTURE.md).

## Examples

```bash
python3 examples/01_transcribe_file.py
python3 examples/02_microphone_stream.py
python3 examples/03_text_integration.py
python3 examples/04_benchmark_offline.py
```

The sample recordings contain short phrases, including words that sound like commands. They are transcription fixtures only. Recognition accuracy varies with audio and model choice; brief phrases can be misheard. Benchmark timings describe inference and exclude process startup and model loading.

## Project layout

```text
src/stt/
  config.py       Local model paths, compute options, and asset checks
  engine.py       Audio file/byte-buffer transcription and result metadata
  stream.py       Microphone transcription, text callbacks, and text queue
  runtime.py      Argmax invocation with network access denied
  audio_utils.py  Audio inspection, conversion, padding, and PCM helpers
scripts/
  setup_models.sh / setup_models.py  One-time asset provisioning
  test_offline.sh                   Offline transcription verification
models/                            Local assets; excluded from Git
assets/samples/                    Audio fixtures
examples/                          Runnable speech-to-text examples
```

## Tests

Unit tests require no microphone or model downloads:

```bash
python3 -m unittest discover tests
```

With both models prepared, run native CoreML tests and the network-denial check:

```bash
STT_INTEGRATION=1 python3 -m unittest discover tests -v
```

For an offline smoke test using the default model:

```bash
bash scripts/test_offline.sh
```

WhisperKit is developed by [Argmax](https://github.com/argmaxinc/argmax-oss-swift).
