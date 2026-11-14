# Local Control — Offline Hand Mouse and Voice Targeting

On an Apple Silicon Mac, move the pointer with your index finger, pinch to click, and name nearby visible text to target it. Camera recognition, speech transcription, screen text recognition, and Bonsai inference all run locally.

**Voice positions the pointer; it never clicks.** For example, point near a visible label and say “Codex.” The pointer moves to the recognized target and locks in place. For the first **3 seconds**, finger movement cannot pull it away, giving you time to pinch your thumb and middle finger for a left click.

## Launch

On the Mac with models and runtimes already prepared, double-click **[Local Control.app](<.build/Local Control.app>)** in Finder. The `.build` folder is hidden; press `⌘⇧.` in the project folder to show it, or run this command from the project directory:

```bash
open ".build/Local Control.app"
```

Alternatively, launch from the command line:

```bash
python3 desktop.py
```

You can also double-click **[Launch Local Control.command](<Launch Local Control.command>)** in the project folder. The launcher builds the native helper if it is missing and starts the installed local Bonsai service when needed. It does not download missing models.

The `.app` is a Finder launcher for the prepared project. Keep the project files, Argmax models, and Bonsai/MLX runtime in their existing locations. Copying the `.app` alone to another Mac is not sufficient. If you move the project directory, run `bash scripts/build_product.sh` again.

On first use, open **System Settings → Privacy & Security** and grant permissions to Local Control or the terminal identified by macOS:

- **Camera**: recognize your hand.
- **Microphone**: capture speech for transcription.
- **Accessibility**: move the pointer and send clicks.
- **Screen Recording**: read visible text near the pointer.

You may need to quit and restart after changing permissions. The app starts **PAUSED**. Click **Enable pointer** in the preview window, or press Space while that window is active.

| Input | Behavior |
| --- | --- |
| Move your index finger | Move the pointer on the primary display |
| Pinch thumb + middle finger | Left click; release before triggering another click |
| Pinch thumb + ring finger | Right click |
| Say nearby text, such as “Codex” | Argmax transcription → local OCR → Bonsai selection → pointer positioning; no click |
| Move your finger during the first 3 seconds after targeting | Keep the pointer on the target while you prepare a pinch |
| Move your hand deliberately after 3 seconds | Release the lock; a steady hand keeps the target locked |
| Space, while the control window is active | Enable or pause |
| Escape | Pause control |
| Q, while the control window is active, or close the window | Quit |

A pinch click releases the lock immediately. Pausing or losing reliable hand tracking also clears the lock immediately, including during the 3-second protection period.

Additional launch options:

```bash
python3 desktop.py --check
python3 desktop.py --gesture-only
python3 desktop.py --speech-model base --language auto
```

`--check` inspects installed assets, the native app, and the running model service; it does not start Bonsai automatically. `--gesture-only` runs the camera and hand mouse without voice targeting.

## Local Models and Offline Setup

Requirements: Apple Silicon, macOS 14+, Python 3.9+, Xcode Command Line Tools, and Argmax's `whisperkit-cli`. Hand tracking and OCR use the Vision framework bundled with macOS, without browser CDNs or additional Python vision libraries.

Install and cache Argmax during the online preparation stage:

```bash
brew install whisperkit-cli
bash scripts/setup_models.sh --model base --language auto
bash scripts/build_product.sh
```

The desktop app defaults to **multilingual Whisper base**, which supports Chinese and English. `tiny.en` and `base.en` are English-only models; `tiny` and `base` are multilingual. Models and tokenizers are stored in the project's `models/` folder and are not committed to Git.

Bonsai uses the **Ternary Bonsai-2 2B** model already installed on this Mac:

```text
~/.lmstudio/models/prism-ml/Ternary-Bonsai-2-2B-mlx-2bit
```

`scripts/start_bonsai.sh` uses LM Studio's installed MLX runtime with support for this model. It binds the service to `127.0.0.1:1234` with the model ID `bonsai-local`. To start it manually:

```bash
bash scripts/start_bonsai.sh
```

On another Mac, install compatible models and runtimes in advance. Use `BONSAI_MODEL_PATH` and `BONSAI_PYTHON` to specify their local paths. The launcher will not fetch missing dependencies from the cloud. The HTTP interface belongs to **the local Bonsai service**. Argmax runs through its native Swift CLI; **the Argmax Local Server API is not used**.

Before disconnecting from the internet, complete the setup above and build the Finder launcher with `bash scripts/build_product.sh`. Keep the project, models, and runtime folders in place; the launcher is not a standalone transferable bundle.

Argmax inference processes are denied network access. The Bonsai startup script blocks external networking, permits only local loopback connections, and enables the model libraries' offline modes. `127.0.0.1` remains available when Wi-Fi is off.

**Verification on November 14, 2026:** With Wi-Fi switched off, the camera, real screen OCR, and a synthesized-speech pipeline using real Argmax, Bonsai, and the coordinator passed their checks and produced the correct `Codex` movement instruction. Wi-Fi was restored afterward. In a separate live test with **Wi-Fi on**, a user said “Codex,” the pointer moved to the target, and hand gestures performed left and right clicks. Saying “Safari” followed by a left-click gesture also worked, and the local browser test board received the clicks. These tests used different network states and inputs; a complete live demonstration video with Wi-Fi off has not yet been recorded. See the [verification record](docs/VERIFICATION.md) for evidence and the [demo guide](docs/DEMO.md) for the procedure.

## Targeting Scope and Current Limitations

- Targets come from an OCR region of approximately **720 × 420** screen points around the pointer when speech begins. Move near the target first.
- Bonsai selects IDs for text already recognized by OCR; it does not generate mouse coordinates.
- Duplicate labels, missing text, ambiguous matches, and expired results do not trigger targeting.
- Targeting supports currently visible text. It does not recognize arbitrary icons across the screen, find hidden labels, or navigate interfaces autonomously.
- The prototype targets the primary display. Occluded windows, small text, lighting, hand posture, and noise can affect recognition.
- Live testing has covered `Codex` and `Safari` on the local test board. Use the [two-minute demo checklist](docs/DEMO.md) to verify other applications, target layouts, and a complete recording with Wi-Fi off.

## Standalone Text-Only Transcription Interface

The original `src/stt`, `cli.py`, and `main.py` interfaces still return text only. They do not recognize gestures or execute actions:

```bash
python3 cli.py check
python3 cli.py transcribe assets/samples/select_this_item.wav --json
python3 cli.py stream
```

```python
from stt import STTConfig, WhisperKitEngine

engine = WhisperKitEngine(STTConfig(model_name="base", language="auto"))
print(engine.transcribe("recording.wav").text)
```

Run API examples with `PYTHONPATH=src python3 your_script.py`. `WhisperKitStreamer` provides an `on_text` callback and `get_text(timeout)`. The STT layer never interprets spoken text as an action.

## Tests and Documentation

```bash
python3 -m unittest discover tests -v
STT_INTEGRATION=1 python3 -m unittest discover tests -v
.build/LocalControl.app/Contents/MacOS/GestureCamera --self-test
python3 scripts/test_product_offline.py
```

The second command requires prepared `tiny.en` and `base.en` models and permission to access CoreML hardware. It tests real inference and the network-denial policy. The native `--self-test` does not open the camera or operate the mouse. The last command verifies the real OCR → Argmax → Bonsai → movement-instruction pipeline using synthesized audio and a generated image; it does not operate the system mouse.

- [Product interaction guide](docs/PRODUCT.md)
- [System architecture and data boundaries](docs/ARCHITECTURE.md)
- [Offline acceptance checks and hackathon demo script](docs/DEMO.md)
- [Verified scope and reproduction steps](docs/VERIFICATION.md)
- [Offline setup for the standalone speech module](docs/OFFLINE_SETUP.md)

Dependencies: [Argmax WhisperKit](https://github.com/argmaxinc/argmax-oss-swift), [Apple Vision](https://developer.apple.com/documentation/vision), and the locally installed PrismML Bonsai-2 model and LM Studio MLX runtime.
