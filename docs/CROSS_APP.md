# Cross-Application Targeting

Local Control uses system mouse events and local screen discovery. It does not depend on the demo board, website selectors, browser JavaScript, a browser extension, or an application whitelist.

Point near the intended control, say its visible label or accessible name, and pinch to click after the pointer reaches it. A cyan ring and a click-through caption identify the target. The caption counts down the three-second protection period, then displays “Pinch to click.” A click, pause, tracking loss, or deliberate movement after the protection period clears the lock and highlight. Beginning another voice search hides the old highlight before capture.

## Discovery and Selection

1. Speech onset captures a region of about 720 × 420 points around the pointer on the primary display.
2. A bounded, read-only macOS Accessibility scan collects named visible controls. Each accepted control is checked against an accessibility hit test at its screen position. This covers native menus, folder icons, browser tabs, links, and named toolbar buttons.
3. Vision OCR supplies visible text when an application does not expose useful control names. Word boxes preserve the positions of individual labels instead of aiming at the center of a whole text line.
4. Accessibility and OCR readings of the same control are merged. Finder icon captions are associated through element identity even when their text sits below the icon. Distinct controls with the same name remain distinct and ambiguous.
5. Argmax returns a transcript. Local Bonsai receives only candidate IDs and labels, with likely name matches presented first. Every candidate remains available to the model. It selects an existing ID or abstains; it never supplies coordinates or executes commands.
6. The coordinator validates the result and requests movement to the captured target. Only the hand gesture path sends clicks.

Accessibility reads do not request text-field values, selected text, or document contents, and do not perform accessibility actions. OCR reads the visible pixels in the local capture region. The target scanner does not download assets or make network requests. Bonsai and Argmax keep their existing offline network restrictions.

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
.build/LocalControl.app/Contents/MacOS/GestureCamera --targets-at 480 220
```

Normal runtime does not save these diagnostic snapshots. Explicit diagnostics can contain visible screen labels, so keep their output local when it includes personal content.

## Limits

- Visible, named controls work best. Unlabeled icons, custom canvases without accessibility names, hidden controls, and protected content may have no usable target. Hand movement and pinch clicks still operate the system pointer.
- Discovery stays near the pointer and on the primary display. Move closer to a target first; scrolling, window rearrangement, or content changes during recognition can invalidate the captured location.
- Distinct controls with the same name require a clearer label or a closer pointer position that excludes the other control. The program does not guess between them.
- Model output can still be invalid or unrelated, especially with noisy speech or crowded interfaces. Validation rejects those results without a coordinate fallback or automatic click.
- Voice phrases such as “open Reports” mean **position the pointer on Reports**. Opening the folder still requires the normal user gesture or interaction.

The regression suite includes request wrappers, full-name priority, ambiguity, Unicode label normalization, offline boundaries, native clipping and coordinate conversion, Finder read-only containers, duplicate caption removal, and target-overlay geometry. On this revision, **91 Python tests** (including real Argmax checks) and **51 native checks** passed.
