# Offline Setup Guide: Running 100% Without Wi-Fi

This project is built to execute all speech-to-text operations **fully locally on Apple Silicon** with zero network calls and zero internet/Wi-Fi dependencies during runtime.

---

## 1. Prerequisites (One-Time Setup)

To run offline, the following two components must be present on your Mac:

1. **`whisperkit-cli`**: The Apple Silicon inference CLI created by Argmax Inc.
   ```bash
   brew install whisperkit-cli
   ```
2. **Model Weights**: The compiled CoreML model files and tokenizer.
   Run the automated setup script once while connected to the internet:
   ```bash
   bash scripts/setup_models.sh
   ```

---

## 2. Model Storage Layout

The offline models are saved directly inside this repository under the `models/` directory:

```
models/
├── argmaxinc/
│   └── whisperkit-coreml/
│       ├── openai_whisper-tiny.en/      # ~146 MB CoreML weights (AudioEncoder, TextDecoder, Mel)
│       └── openai_whisper-base.en/      # ~250 MB CoreML weights (higher accuracy option)
└── openai/
    ├── whisper-tiny.en/                 # Tokenizer files (tokenizer.json, config.json)
    └── whisper-base.en/                 # Base tokenizer files
```

When you disconnect from Wi-Fi, the engine automatically resolves these local paths and never queries Hugging Face or external servers.

---

## 3. Verifying Offline Readiness

To verify that your environment can operate without internet access, run:

```bash
./cli.py check
```

Expected output:
```
=================================================================
 Argmax WhisperKit Offline Environment Check
=================================================================
  CLI Binary              : /opt/homebrew/bin/whisperkit-cli
  CLI Installed           : ✓ Yes
  Model Name              : openai_whisper-tiny.en
  Model Path              : .../models/argmaxinc/whisperkit-coreml/openai_whisper-tiny.en
  Model Downloaded        : ✓ Yes
  Tokenizer Path          : .../models/openai/whisper-tiny.en
  Tokenizer Downloaded    : ✓ Yes
  Audio Encoder Compute   : cpuAndNeuralEngine
  Text Decoder Compute    : cpuAndNeuralEngine
-----------------------------------------------------------------
  STATUS: [✓] 100% OFFLINE READY
  Speech-to-text will run completely locally without Wi-Fi.
=================================================================
```

---

## 4. Hardware Compute Units

By default, the engine configures inference to run on Apple's **Neural Engine** for maximum energy efficiency and lowest latency:

* `cpuAndNeuralEngine` *(Recommended default)*: Audio encoder runs on the Apple Neural Engine (ANE); text decoder runs on CPU/ANE. Latency is typically **35–50 ms**.
* `all`: Allows CoreML to dynamically allocate between CPU, GPU, and Neural Engine.
* `cpuAndGPU`: Directs inference to the Metal GPU.
* `cpuOnly`: Runs inference exclusively on the CPU.

You can customize this in Python:
```python
from stt import STTConfig, WhisperKitEngine

config = STTConfig(
    model_name="tiny.en",
    audio_encoder_compute_units="cpuAndNeuralEngine",
    text_decoder_compute_units="cpuAndNeuralEngine",
)
engine = WhisperKitEngine(config)
```

---

## 5. Offline Verification Script

You can run the end-to-end verification script with Wi-Fi disabled:

```bash
bash scripts/test_offline.sh
```

This verifies model loading, passes all unit tests, and transcribes local audio in ~45 ms with zero internet connectivity.
