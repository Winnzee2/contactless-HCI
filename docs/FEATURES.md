# Jarvis — Feature Guide

Jarvis is an offline macOS interface combining hand gestures, spoken targeting, application navigation, and dictation. This list describes implemented behavior, not planned capabilities.

## Hand and mouse control

| Feature | How it works |
| --- | --- |
| Camera hand tracking | Apple Vision locates wrist and finger joints across the full camera frame. |
| Pointer movement | The index fingertip's absolute camera position maps to the primary screen. |
| Adjustable reach | A remembered 100–150% slider makes screen edges reachable with less hand travel. |
| Motion smoothing | Confidence filtering and adaptive landmark smoothing reduce jitter; cursor movement is smoothed separately. |
| Pinch stabilization | Cursor motion freezes as fingers approach a pinch, helping prevent unintended movement before clicking. |
| Left click | Bring thumb and middle finger together, then release. |
| Double-click | Perform two quick left-click pinch releases at approximately the same position. |
| Right click | Pinch thumb and ring finger together. |
| Vertical scrolling | Hold thumb and pinky together and move the hand vertically. |
| Tracking recovery | Brief gaps are tolerated; longer gaps reset unfinished gestures without generating click edges. |
| Pause/resume | Use Enable pointer / Pause pointer, Space in the control window, or Escape to pause. Q quits from the control window. |

The fist-to-Mission-Control gesture and held-pinch double-click are disabled. Palm-relative pointing was reverted; absolute index position is the active control scheme.

## Voice targeting

- Local microphone activity detection segments speech for Argmax WhisperKit.
- A cached Whisper model transcribes speech, including multilingual input.
- macOS Accessibility supplies control labels; Apple Vision OCR supplies visible screen text.
- The local Bonsai model matches natural-language requests to these screen candidates.
- Saying a visible target name moves the cursor without clicking.
- Targeting searches the primary screen; cursor proximity helps rank matches.
- Named targets are checked again before movement so layout changes can be followed.
- Ambiguous matches receive circles and numbered labels. Say a number to select a displayed position.
- Numbered positions remain fixed through scrolling, typing, and element changes. Say “cancel” to dismiss them.
- A selected target stays locked for up to 15 seconds, allowing time to pinch; clicks release the lock.
- Numbered choices expire after 15 seconds without extending the deadline for invalid choices.
- Transcription survives ordinary screen changes, pinch preparation, and brief hand loss.
- Results can wait briefly for hand reacquisition. Deliberate clicks, application/Space changes, pause, and timeouts cancel pending actions.
- Speech never performs a target click automatically.

## Spoken navigation

| Phrase | Action |
| --- | --- |
| “How Jarvis” | Toggle the cheatsheet while voice control is enabled; during dictation this stays note text. |
| “Last page” / “go back” | Navigate backward in supported browsers and Finder folders. |
| “Tab left” / “tab right” | Select the adjacent browser tab. |
| “Close tab” | Close the current browser tab. |
| “Close window” | Request closure of the active app window through Accessibility. Normal save dialogs remain in control. |
| “Change window” | Raise another non-minimized standard window within the current app. |
| “Switch windows” / “switch apps” | Send a complete Cmd+Tab shortcut. Separate presses normally alternate between the two most recent apps. |
| “All windows” / “show all windows” | Toggle Mission Control to show desktop windows or exit the overview. |

Commands use explicit application rules rather than arbitrary model-generated keyboard actions. Some polite phrasing, Chinese aliases, and narrowly scoped transcription variants are supported. Negations and mentions inside longer sentences are rejected by the command matcher; this is not unrestricted conversational automation.

## Jarvis notes

- Say “Hey Jarvis” to open a floating notepad.
- Include note content immediately after the wake phrase, or continue in successive speech blocks.
- During dictation, navigation phrases are recorded as text rather than executed.
- Say “Bye Jarvis,” press Stop recording, or remain silent for five seconds to finish.
- Pending transcription is completed before the final note is saved.
- Choose a destination using Notes folder…; the selection persists.
- The default folder is Documents/Jarvis Notes.
- Each note is saved as a separate UTF-8 text file with a unique name.
- Existing files are not overwritten. Save failures retain recognized text in memory for folder changes and retry.
- “Bye Jarvis” saves and closes the notepad. Silence or the Stop recording button leaves the saved note visible. Save failures keep the window open for retry; ordinary voice targeting resumes.
- Pausing ends note recording. Quitting can save already recognized text, but cannot recover audio still being transcribed.

## Visual and audio feedback

- Dark graphite main interface with a rounded camera view and gesture reference cards.
- Persistent translucent, click-through speech pane in the upper-right corner; fades to 22% opacity while the cursor is over it.
- Foldable Use cheatsheet below the webcam, covering gestures, targeting, spoken navigation, notes, and keyboard controls. Say “How Jarvis” to toggle it; starts collapsed, remembers its state, and resizes the pane.
- Immediate listening indication, red recognized speech, and separate processing status.
- Full mirrored webcam preview in the floating speech pane, with aligned hand joints, connecting bones, and a highlighted index tip.
- Hand status for pointing, pinches, scrolling, tracking loss, pause, and successful clicks.
- Cyan cursor sensing ring, target highlight with lock countdown, and numbered ambiguity circles.
- Local synthesized cues for target lock, clicks, double-clicks, scrolling, choices, and navigation.
- Remembered Sound effects toggle; cues are suppressed during active speech.
- Coordinated styling for the Jarvis notepad and both offline practice pages.

## Local architecture and developer tools

- Native Swift/AppKit camera, microphone, overlays, gesture logic, and macOS input actions.
- Python coordinator communicating with native and voice worker processes through JSON messages.
- Argmax WhisperKit running a locally cached Whisper model; inference subprocess networking is denied by the existing OS sandbox.
- Bonsai served locally through MLX on the loopback interface.
- Apple Vision hand-pose detection and OCR run on the Mac.
- Finder launcher and command-line launcher; local native build when required.
- Startup checks for installed models and permissions; the launcher can start the installed Bonsai service.
- Gesture-only mode and standalone file/microphone speech-to-text interfaces.
- Offline target board and duplicate-target practice page.
- The Meridian offline newspaper: six fictional stories, section navigation, search, reading-list bookmarks, text-size controls, and browser-history navigation.
- Python regression tests and native self-tests for recognition rules, routing, geometry, and input events.

## Requirements and limits

Apple Silicon, macOS 14 or newer, prepared local models/runtimes, and the required Camera, Microphone, Accessibility, and Screen Recording permissions are needed. Initial installation may require downloads; runtime operation can be offline.

Hand detection uses 2D camera landmarks and can fail with occlusion, poor lighting, or severe tilt. Voice targeting requires readable text or accessible labels; hidden content and unlabeled custom canvases may not be targetable. Cursor and screen discovery currently focus on the primary display. Cmd+Tab switches applications, not every individual window. Jarvis text appears after local transcription, not word-by-word streaming; sustained speech can exceed the bounded transcription backlog and produce an explicitly marked partial note.
