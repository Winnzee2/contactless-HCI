# Local Control — Offline Hand Mouse and Voice Targeting

On an Apple Silicon Mac, move the pointer with your index finger, pinch to click, and name a nearby visible control to target it across applications. Camera recognition, speech transcription, accessibility inspection, screen text recognition, and Bonsai inference all run locally. No browser extension or integration with a particular website is required.

Hand control uses the full camera image. The preview border marks the entire image, and **Pointer reach** adjusts how far index-finger movement travels: 100% gives 1:1 full-frame mapping, while 115% (default) reaches screen edges with slightly less movement. The slider supports 100–150% and remembers your setting. The actual cursor stays within screen bounds. Smoothing and pinch stabilization remain enabled; keep the relevant fingertips and palm landmarks visible to the camera.

A cyan sensing circle follows the cursor while hand control is active. It is a visual focus indicator; voice targeting still searches the entire primary screen. A translucent speech panel stays in the **upper-right corner**, showing “Listening…” immediately at speech onset and recognized words in red when transcription finishes. It remains visible while paused, and recognized words stay until the next utterance. Both overlays are click-through and never take keyboard focus. The speech panel is excluded from screen capture so it cannot become its own recognition target.

**Voice positions the pointer, navigates back, or switches browser tabs; it never clicks.** For example, point near a visible label and say “Codex.” The pointer moves to the recognized target and locks in place. For the first **15 seconds**, finger movement cannot pull it away, giving you time to pinch and release your thumb and middle finger for a left click, or pinch and release twice quickly for a double-click.

A click-through highlight shows the selected target and the remaining hold time. The highlight and lock expire after the countdown. Clicking, pausing, or beginning another voice search also dismisses the highlight.

If several nearby targets match the name you say, the app circles **every matching target** and labels them **1, 2, 3, …**, ordered from top to bottom and left to right. Keep your hand visible and say a number, such as “two,” “number two,” or “第二个.” The pointer moves to that target at the original numbered position, then uses the same 15-second hold. **Choosing a number never clicks.** Say “cancel” to dismiss the circles; they expire after **15 seconds**.

## Architecture

The app combines a native macOS interface with a Python coordinator and local AI inference:

- **Native Swift layer (`native/`):** Captures camera and microphone input, uses Apple Vision for hand landmarks and screen OCR, reads accessible controls, and renders overlays. Gesture logic converts hand positions into native mouse movement, clicks, and scrolling.
- **Python coordinator (`desktop.py`, `src/control/`):** Connects the native helper and voice worker through JSON messages. It manages target selection, numbered choices, timeouts, navigation commands, and Jarvis dictation sessions.
- **Argmax WhisperKit (`src/stt/`):** Runs a locally stored Whisper speech model to convert microphone audio into text. It supplies transcription for both voice targeting and notes; it does not execute commands.
- **Bonsai:** Runs through a local MLX service and matches spoken requests to candidate labels gathered from Accessibility and OCR. Explicit navigation commands and Jarvis dictation use dedicated rules and bypass Bonsai target matching.

The targeting flow is **microphone → Argmax transcription → Bonsai target matching → validated native cursor movement**. Hand gestures perform clicks. Jarvis instead sends transcribed text to the notepad and saves it as a local text file. Once models and runtimes are installed, all processing works offline without cloud APIs.

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
- **Accessibility**: read visible control names, move the pointer, and send clicks.
- **Screen Recording**: read visible text near the pointer.

You may need to quit and restart after changing permissions. The app starts **PAUSED**. Click **Enable pointer** in the preview window, or press Space while that window is active.

| Input | Behavior |
| --- | --- |
| Move your index finger | Move the pointer on the primary display |
| Briefly pinch thumb + middle finger, then release | One left click on release |
| Pinch and release thumb + middle twice quickly at the same position | Natural double-click using macOS’s double-click interval |
| Pinch thumb + ring finger | Right click |
| Hold thumb and pinky together, then move your hand up/down | Scroll up/down under the pointer; release to resume pointer movement |
| Name a nearby control, such as “Codex” or “open Reports” | Argmax transcription → accessibility labels and local OCR → Bonsai selection → pointer positioning; no click |
| Say **“last page”** | Go back to the previous page in the active browser or the previously visited folder in Finder, without moving or clicking the pointer |
| Say **“tab left”** or **“tab right”** | Switch to the adjacent tab on that side in the active browser window, even when tab names are truncated |
| Say “two,” “number two,” or “第二个” while numbered circles are visible | Select position 2 and move the pointer there; no click |
| Say “cancel” while numbered circles are visible | Dismiss the choices |
| Move your finger during the 15 seconds after targeting | Keep the pointer on the target while you prepare a pinch |
| Wait 15 seconds after targeting | Release the pointer lock |
| Space, while the control window is active | Enable or pause |
| Escape | Pause control |
| Q, while the control window is active, or close the window | Quit |

A single click, double-click, or right click releases the target lock. Each middle-finger pinch release sends one click immediately. Two rapid releases within eight screen points form a double-click; holding the pinch never fires a click. The pointer stays at the pinch position until you release.

With control enabled and your hand visible, say **“last page”** to use Back in the active browser or Finder window. In Finder, it returns to the previously visited folder in that window's navigation history. The phrase works without a readable screen target and clears any numbered choices or pointer lock. It must be the complete utterance; a sentence mentioning “last page” does not navigate. Recognition and command handling stay local. Local folders remain available without Wi-Fi; offline web content must already be available locally or in the browser cache. The command uses the standard macOS Command-[ Back shortcut; without a previous history entry, nothing changes.

With a browser window active, say **“tab left”** or **“tab right”** to switch one tab in that direction. Keep control enabled and your hand visible. These complete utterances use the browser's previous/next-tab shortcut, so they work without reading the tab titles. They clear numbered choices and the pointer lock, send no click, and run locally. First/last-tab behavior follows the browser's normal tab cycling. Tab switching applies to browsers; Finder continues to support **“last page”** for folder history.

The fist-to-Mission-Control gesture is disabled. Hand tracking uses the full camera frame at up to 30 updates per second, per-landmark adaptive smoothing, and confidence hysteresis. Brief tracking gaps hold the current state for up to 150 ms without generating actions; longer gaps reset gesture recognition.


Pausing cancels unfinished gestures and voice actions. Losing reliable hand tracking resets unfinished gestures but preserves speech and displayed target prompts. Open your fingers before starting another pinch after a pause or tracking loss.

Numbered choices keep their original numbers and search area while you move your hand. A click, pause, explicit cancel, navigation action, or timeout clears them. Element changes, scrolling, typing, and brief tracking loss preserve the original numbered positions. Invalid or out-of-range numbers do not move the pointer or restart the 15-second countdown.

For local practice, open the [offline target board](assets/demo/target-board.html) or the [duplicate-target practice page](assets/demo/duplicate-targets.html). On the duplicate page, point near the middle button, say “Reports,” wait for the circles, then say a number and pinch to click. Both pages work without a network connection; the same discovery and selection code is used in other applications.

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

The current build also passed **five actual target-selection checks with Wi-Fi off** in Finder, TextEdit, and Safari. Those checks used supplied transcript text and verified local model selection and target coordinates without clicking. See the [cross-application record](docs/CROSS_APP.md) for the cases and reproduction commands.

## Targeting Scope and Current Limitations

- Targets are discovered across the primary screen. The pointer position helps rank nearby matches.
- macOS Accessibility supplies visible names and bounds for native controls, browser tabs, links, menus, folder icons, and named toolbar icons. Local Vision OCR supplies visible text when accessibility labels are unavailable. Individual word geometry avoids aiming between neighboring labels.
- The scanner checks visibility, keeps bounded traversal times, and combines accessibility and OCR readings of the same control. The demo board is an optional test fixture; no app names or website selectors are required for discovery.
- The control layer narrows the candidate list to visible labels supported by the spoken name, preserving their original labels and IDs and every matching duplicate. This prevents unrelated screen instructions from distracting Bonsai, including on the offline target board. The filtering uses generic English and Chinese name matching, not a list of supported websites or target names.
- Bonsai must still return a valid candidate ID or a valid null response. It never generates coordinates. A unique target requires a valid model selection; multiple matches open numbered circles and leave the pointer in place until you say a valid number. Argmax only transcribes the follow-up; a local number parser resolves the displayed number.
- Numbered choices remain bound to the original screen area and expire after 15 seconds. Number selection uses the saved positions, even if the original labels change or disappear. Invalid model output and expired results do not trigger targeting.
- Use the displayed label or accessible control name. Unlabeled icons, inaccessible custom canvases, hidden content, and protected screens cannot be targeted reliably by voice. Ordinary hand pointer movement and pinch clicks remain available.
- The prototype targets the primary display. Occluded windows, small text, lighting, hand posture, and noise can affect recognition.
- See the [cross-application checks](docs/CROSS_APP.md) for real-app verification and a reusable diagnostic. Compatibility depends on what each application exposes; a finite test set cannot establish support for every control in every app.

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
- [Cross-application targeting and verification](docs/CROSS_APP.md)
- [Offline setup for the standalone speech module](docs/OFFLINE_SETUP.md)

Dependencies: [Argmax WhisperKit](https://github.com/argmaxinc/argmax-oss-swift), [Apple Vision](https://developer.apple.com/documentation/vision), and the locally installed PrismML Bonsai-2 model and LM Studio MLX runtime.

Voice recognition searches the entire primary screen. Pointer sensitivity is increased, with stronger smoothing to reduce jitter. As thumb approaches the middle, ring, or pinky finger, the cursor freezes before contact; opening the fingers releases it.

Pinch contact uses multiple palm axes to tolerate hand rotation and foreshortening. Middle, ring, and pinky contacts use a more forgiving threshold and a shorter release distance. An active click keeps ownership when adjacent fingers move close; an obscured unrelated fingertip no longer drops all hand tracking. Keep the thumb, intended fingertip, and enough palm landmarks visible; fully occluded contacts cannot be determined by the camera.

Target prompts now use fixed screen positions. Numbered circles keep their original positions for their 15-second lifetime even when page elements change, move, or disappear. Saying a number moves to that displayed position without clicking. A selected focus point stays locked for 15 seconds. Hand motion, brief tracking loss, and starting a pinch do not dismiss an existing prompt; a click, timeout, explicit cancellation, pause, or a new navigation action clears it.

Short offline sound effects distinguish target lock, single/double click, scrolling start, numbered choices, and navigation. Toggle **Sound effects** in the app; the setting is remembered. Microphone capture briefly pauses during playback to avoid recognizing the app’s own tones.

Natural requests include “Could you take me to the Codex tab please,” “帮我找一下 Codex,” “Please go back,” and “Switch to the tab on the left.” Visible names tolerate one missing, extra, swapped, or incorrect character for names of at least four characters; exact matches take priority and competing corrections produce numbered choices. This is bounded error tolerance, not unrestricted command execution. Argmax still transcribes locally, and Bonsai selects only supplied screen targets.

Say **“close tab”** to send Command-W to the current browser tab. Closing the final tab follows the browser’s normal window behavior. The former “alt tab” alias has been removed; use “tab left” or “tab right” for browser tabs. Control must be enabled, the browser active, and your hand visible. These commands run fully offline.

Say **“close window”** to press the active app window’s close button, or **“change window”** to raise another non-minimized window of the same app. These use macOS Accessibility window actions, not browser-tab shortcuts. Apps must expose accessible windows, and normal unsaved-document dialogs remain under your control. The persistent top-right speech panel uses monospaced typography, a translucent charcoal background, muted status text, and red recognized speech.

### Speech continuity

While control is enabled, listening is independent of hand tracking and ordinary screen activity. Hover effects, animations, typing, scrolling, pinch preparation, and brief tracking gaps do not discard the recording. Sound cues are suppressed during active speech.

A named target is checked again against the current screen before the pointer moves. If it moved, the pointer follows its refreshed location; if it disappeared or became ambiguous, the app asks you to name it again. Already displayed numbered choices remain anchored to their original positions and keep their original 15-second deadline.

If recognition finishes while your hand is missing, the app waits up to five seconds for it to return before applying the result. A real click, switching apps or Spaces, pausing, or expiration cancels pending actions. No unfinished requests are replayed later. Voice still never clicks a target automatically.

### Jarvis notepad

Choose **Notes folder…** in the main window (or in the notepad) to select where .txt notes are saved. The folder is remembered. Until you choose one, notes use ~/Documents/Local Control Notes.

With voice control enabled, say **“Hey Jarvis”**. A small floating notepad opens; speak your note naturally. You can include the note in the same utterance as the wake phrase. Speech is transcribed locally with Argmax, and successive speech blocks are collected into one note. During dictation, words such as “close window” are note text and never execute commands.

Say **“Bye Jarvis”**, press **Stop recording**, or leave **five seconds of silence** to finish. The silence timer uses microphone activity rather than transcription completion. Pending transcription finishes before saving, so “Finishing” can remain visible briefly after recording stops. The wake and stop phrases are omitted from the note. Argmax's end-of-utterance “buy Jarvis” / “by Jarvis” homophones also stop recording.

Each session saves a separate UTF-8 text file with a unique identifier; existing notes are not overwritten. The window shows the saved path. If saving fails, text remains in memory: choose another folder or use **Retry save** before quitting. Quitting saves text already recognized, but cannot recover audio still being transcribed. A bounded transcription backlog stops with an explicit partial-note message if inference cannot keep up. The notepad remains visible after saving, while ordinary voice targeting resumes. No cloud service is used.
