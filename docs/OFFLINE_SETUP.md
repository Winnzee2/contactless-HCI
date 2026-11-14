# Offline speech recognition with Argmax WhisperKit

This module produces transcript text only. It does not interpret speech as commands or perform application actions.

## One-time online setup

Use an Apple Silicon Mac running macOS 14 or later, Python 3.9 or later, and Homebrew:

```bash
brew install whisperkit-cli
bash scripts/setup_models.sh
```

The default is `tiny.en`, an English model. For higher accuracy use `bash scripts/setup_models.sh --model base.en`, or `--model all` to prepare both. Setup downloads compiled CoreML assets from `argmaxinc/whisperkit-coreml` and the matching OpenAI Whisper tokenizer from Hugging Face. Downloads use a resolved repository revision and temporary files; failed downloads exit with an error. Setup verifies a sample transcription with network access denied before reporting success.

Python inference requires only the standard library. No cloud account, API key, Python ML runtime, or paid Argmax service is needed.

## Local assets

```text
models/
  argmaxinc/whisperkit-coreml/openai_whisper-tiny.en/
    AudioEncoder.mlmodelc/
    TextDecoder.mlmodelc/
    MelSpectrogram.mlmodelc/
  openai/whisper-tiny.en/
    tokenizer.json
    tokenizer_config.json
    config.json
```

The base model uses the same layout with `base.en` in place of `tiny.en`. Model weights are excluded from Git, so a new clone must run setup while online or copy these folders from a prepared machine.

`python3 cli.py check` checks the executable, required model files, tokenizer JSON files, and availability of the macOS network sandbox. It exits nonzero if anything is missing. This checks file presence and JSON readability; the setup smoke test additionally verifies that CoreML can load the model and recognize speech.

## Run without Wi-Fi

```bash
python3 cli.py transcribe assets/samples/select_this_item.wav
python3 cli.py transcribe recording.m4a --model base.en --json
python3 cli.py stream
```

File and microphone inference pass explicit local model and tokenizer paths to Argmax. Both launch through `/usr/bin/sandbox-exec` with networking denied. Missing or invalid assets produce an error; inference cannot silently download replacements. Only the setup script has a download path. This sandbox applies to the inference subprocess, without changing your Mac's network settings.

For microphone streaming, grant microphone access to the terminal or hosting app in **System Settings → Privacy & Security → Microphone**. `[Listening]` text is provisional and may change. `[Speech]` text is confirmed; each newly confirmed segment is emitted as plain text. Confirmation may lag while Argmax stabilizes its output. Ctrl+C stops capture and discards unconfirmed text.

## Verify

```bash
bash scripts/test_offline.sh
```

This checks assets, runs unit tests, and performs real transcription with networking denied. Wi-Fi may remain on because the process policy blocks networking; you can also run it with Wi-Fi disabled.

For both model variants and an explicit socket-denial test:

```bash
bash scripts/setup_models.sh --model all
STT_INTEGRATION=1 python3 -m unittest discover tests -v
```

Native tests need normal CoreML hardware access. A restricted development sandbox can prevent access to Apple Neural Engine services or prevent nested sandbox creation; run the commands in a regular terminal in that case.

## Compute and timeouts

The default `cpuAndNeuralEngine` enables CPU/ANE inference. `all`, `cpuAndGPU`, and `cpuOnly` are also accepted by the Argmax CLI. Latency depends on the model and device. `pipeline_duration` is the inference timing reported by Argmax; CLI JSON also includes `wall_sec`, which includes startup and loading.

```python
from stt import STTConfig, WhisperKitEngine

engine = WhisperKitEngine(STTConfig(
    model_name="tiny.en",
    audio_encoder_compute_units="cpuAndNeuralEngine",
    text_decoder_compute_units="cpuAndNeuralEngine",
    transcription_timeout=120,
))
result = engine.transcribe("recording.wav")
print(result.text)
```

Run application scripts with `PYTHONPATH=src python3 your_script.py`. Increase `transcription_timeout` for long recordings. If a cache is corrupted, remove the affected model/tokenizer folder and rerun setup while online. The runtime never repairs it by downloading.

Upstream documentation: [Argmax SDK and WhisperKit CLI](https://github.com/argmaxinc/argmax-oss-swift).

Recognition is not exact: in local validation, `base.en` misheard the 0.59-second `zoom_in.wav` clip even though model loading and offline inference succeeded. Longer, clearly spoken phrases generally provide more context. Test your intended speech and recordings with the selected model.
