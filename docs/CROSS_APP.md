# Cross-Application Targeting

Jarvis uses system mouse events and local screen discovery. Target discovery does not depend on the demo board, website selectors, browser JavaScript, a browser extension, or an application whitelist.

Point near the intended control, say its visible label or accessible name, and pinch to click after the pointer reaches it. Briefly pinch thumb and middle finger, then release for one left click; repeat the pinch and release quickly at the same position for a natural double-click. Thumb and ring finger perform a right click. The pointer stays at the pinch position while you hold it, and holding a pinch fires no click until release.

A cyan ring and a click-through caption identify the voice target. The caption counts down the three-second protection period, then displays “Pinch to click.” A click, pause, tracking loss, or deliberate movement after the protection period clears the lock and highlight. Beginning another voice search hides the old highlight before capture.

When several nearby targets match the same spoken name, each gets a numbered circle. The pointer stays where it is until you say a displayed number, such as “two,” “number two,” or “第二个.” The selected target is checked again before the pointer moves, then receives the usual three-second hold. You still use a hand gesture to click.

The fist-to-Mission-Control gesture is disabled. Starting a pinch or fist gesture invalidates any pending voice result so that an old result cannot move the pointer during the action. Voice cannot double-click or open Mission Control. The explicit phrase “last page” sends Back to the active browser or Finder window. In Finder, it returns to the previously visited folder in that window's navigation history. Naming a target continues to position the pointer without clicking.

When browser tab titles are shortened or hidden, say “tab left” or “tab right” as a complete utterance to switch to the adjacent tab in the active browser window. Control must be enabled and your hand visible. These browser-only commands use previous/next-tab shortcuts instead of title matching, clear numbered choices and pointer locks, and send no mouse click. They run fully locally and follow the browser's normal cycling behavior at the first or last tab. Finder folder history remains available through “last page.”

Pointer reach is adjustable from 100–150%, with a saved 115% default. At 100%, the full camera frame maps 1:1 to the screen. Higher values reach screen edges with less hand movement.

## Discovery and Selection

1. Speech onset captures a region of about 720 × 420 points around the pointer on the primary display.
2. A bounded, read-only macOS Accessibility scan collects named visible controls. Each accepted control is checked against an accessibility hit test at its screen position. This covers native menus, folder icons, browser tabs, links, and named toolbar buttons.
3. Vision OCR supplies visible text when an application does not expose useful control names. Word boxes preserve the positions of individual labels instead of aiming at the center of a whole text line.
4. Accessibility and OCR readings of the same control are merged. Finder icon captions are associated through element identity even when their text sits below the icon. Distinct controls with the same name remain separate candidates.
5. Argmax returns a transcript. Generic English and Chinese name matching narrows the model input to candidates supported by that transcript, preserving original labels and IDs and all matching duplicates. Bonsai receives only IDs and labels through request-local ID aliases. It must return a valid candidate ID or null; it never supplies coordinates or executes commands. Removing unrelated screen prose also fixes the offline target board's “No confident match” failure for correctly recognized target names.
6. A unique valid selection requests movement to the captured target. Multiple matching targets produce numbered circles without moving the pointer. The follow-up number is transcribed locally by Argmax and interpreted only within that displayed choice set. Fresh screen checks bind the selection to the target's current position. Only the hand gesture path sends clicks.

Accessibility reads do not request text-field values, selected text, or document contents, and do not perform accessibility actions. OCR reads the visible pixels in the local capture region. The target scanner does not download assets or make network requests. Bonsai and Argmax keep their existing offline network restrictions.

## Choosing Between Duplicate Targets

The app numbers all matching targets in the original search region from top to bottom and left to right. The numbers and original search area stay fixed while your hand moves. Keep your hand visible, wait for the circles, then say one displayed number. “Two,” “number two,” and “第二个” all identify target 2. Say “cancel” to dismiss the choices. Circles are click-through and do not take keyboard focus.

Choices expire after **15 seconds**. An unrecognized or out-of-range number leaves the same choices available for the remaining time; it does not extend the deadline. A pause, tracking loss, pinch or fist gesture, mouse click, scroll, keypress, application switch, or desktop Space change clears the choices. Say the target name again to start a new search.

Before processing the number, the app recaptures the original region with its overlays hidden and matches each original choice to one fresh target by label and nearby bounds. It checks the selected target once more after transcription, immediately before moving. Missing, moved, or ambiguous targets cancel the selection rather than reassigning the displayed numbers. The resolved number only positions the pointer; the usual three-second protection period gives you time to pinch.

Open the [duplicate-target practice page](../assets/demo/duplicate-targets.html) locally to try three buttons named “Reports.” Point near the middle button, say “Reports,” then say the number on the intended circle and pinch to click. The [original offline target board](../assets/demo/target-board.html) remains available for unique names. These fixtures need no network and do not receive special treatment in discovery or selection.

## Actual App Checks

Verified on **November 14, 2026, Eastern time** (**November 15, 00:28 UTC**) on the prepared Apple Silicon Mac. Wi-Fi was **On → Off during all five checks → On afterward**. These checks used the actual native scanner and installed Bonsai model on `127.0.0.1:1235`, with disposable local files and folders.

| Application | Visible target | Supplied transcript | Target source | Result |
| --- | --- | --- | --- | --- |
| Finder | Reports folder | `open Reports` | Accessibility image | Passed |
| Finder | Reference Files folder | `Find Reference Files` | Accessibility image | Passed |
| TextEdit | Format menu (`格式` on this Mac) | `打开格式菜单` | Accessibility menu item | Passed |
| Safari | Project Notes link in a plain local document | `Project Notes` | Accessibility link | Passed |
| Safari | New Tab toolbar button (`新建标签页`) | `新建标签页` | Accessibility button | Passed |

For each case, the actual model selected the expected native target ID, and the resolved coordinate was inside that target's captured bounds. These runs supplied transcript text: they did **not** exercise microphone input, physical hand gestures, or mouse actuation. They are evidence of cross-app discovery and model selection, not a claim that every application or control works. The separate [verification record](VERIFICATION.md) documents real speech inference and earlier human gesture tests.

The final build also passed the existing Wi-Fi-off hardware and speech pipeline checks at **01:07:45 UTC**: 30 camera frames, zero Vision failures, real screen OCR, and synthesized local speech through Argmax → Bonsai → the coordinator. The captured movement instruction selected Codex; that test sent no system mouse input. Wi-Fi was restored afterward. The target highlight was separately rendered and visually inspected over the Finder fixture.

The captured reports and Wi-Fi state record are in the ignored `.build/verification/cross-app/` directory. Screen captures and accessibility snapshots are not committed. The generic diagnostic itself is included in the repository.

## Check Another Application

Start the prepared local model service, leave the target application visible, and choose a nearby point in screen coordinates. Use the exact label exposed on your Mac; labels follow the application's language.

```bash
bash scripts/start_bonsai.sh
```

In another terminal, for a Finder folder named Reports near the example coordinates:

```bash
python3 scripts/test_cross_app.py \
  --x 480 --y 220 \
  --expected-label Reports \
  --transcript 'open Reports' \
  --output .build/verification/reports-folder.json
```

Adjust the point and label to your current window layout. The script requires an already-running local Bonsai service. It captures the current region and asks the actual model to select a target. It never moves the pointer, clicks, opens a camera or microphone, or changes Wi-Fi. Failure replaces any previous success report. A separate native diagnostic can inspect candidates without contacting the model:

```bash
.build/JarvisEngine.app/Contents/MacOS/GestureCamera --targets-at 480 220
```

Normal runtime does not save these diagnostic snapshots. Explicit diagnostics can contain visible screen labels, so keep their output local when it includes personal content.

## Limits

- Visible, named controls work best. Unlabeled icons, custom canvases without accessibility names, hidden controls, and protected content may have no usable target. Hand movement and pinch clicks still operate the system pointer.
- Discovery stays near the pointer and on the primary display. Move closer to a target first; scrolling, window rearrangement, or content changes during recognition can invalidate the captured location.
- Distinct nearby controls matching the same name are numbered for spoken selection. Only targets discovered in the original region are included; move closer and start again if the intended control is outside that area.
- Model output can still be invalid or unrelated, especially with noisy speech or crowded interfaces. Validation rejects those results without a coordinate fallback or automatic click.
- Voice phrases such as “open Reports” mean **position the pointer on Reports**. Hold the thumb-and-middle-finger pinch for about 0.7 seconds to double-click and open that folder.

The cross-application revision recorded above passed **91 Python tests** (including real Argmax checks) and **51 native checks**. Its checks cover request wrappers, full-name priority, ambiguity, Unicode label normalization, offline boundaries, native clipping and coordinate conversion, Finder read-only containers, duplicate caption removal, and target-overlay geometry. Those earlier runs do not constitute physical-hand acceptance of the subsequently added held-pinch and fist-open gestures.
