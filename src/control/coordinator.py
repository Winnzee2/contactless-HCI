"""State machine for voice target selection, independent of device access."""

from dataclasses import dataclass, replace
import math
import time
from typing import Dict, Optional

from .bonsai import _name
from .notes import Notes, wake_text


@dataclass
class Search:
    request_id: str
    generation: int
    x: float
    y: float
    started_at: float
    region: tuple
    targets: Optional[list] = None
    audio: Optional[dict] = None
    submitted: bool = False
    choice_id: Optional[str] = None


@dataclass(frozen=True)
class ChoiceOption:
    number: int
    id: str
    label: str
    x: float
    y: float
    width: float
    height: float

    def payload(self):
        return {key: getattr(self, key) for key in
                ("number", "id", "label", "x", "y", "width", "height")}


@dataclass(frozen=True)
class Choices:
    choice_id: str
    generation: int
    x: float
    y: float
    region: tuple
    expires_at: float
    options: tuple
    acknowledged: bool = False


@dataclass(frozen=True)
class PendingMove:
    request_id: str
    generation: int
    label: str
    started_at: float


@dataclass(frozen=True)
class PendingNavigation:
    request_id: str
    generation: int
    action: str
    started_at: float


NAVIGATION_MESSAGES = {
    "all_windows": {"start": "Showing all desktop windows…", "sent": "Mission Control requested.",
                    "retry": "Window overview was not confirmed. Say “all windows” again.", "phrase": "all windows"},
    "close_window": {"start": "Closing the active window…", "sent": "Window close requested.",
                     "retry": "Window close was not confirmed. Try again.", "phrase": "close window"},
    "change_window": {"start": "Switching app windows…", "sent": "Next app window requested.",
                      "retry": "Window switch was not confirmed. Try again.", "phrase": "change window"},
    "close_tab": {"start": "Closing the current browser tab…", "sent": "Close-tab shortcut sent.",
                  "retry": "Close tab was not confirmed. Say “close tab” again.", "phrase": "close tab"},
    "back": {"start": "Going back to the previous page…", "sent": "Back navigation sent.",
             "retry": "Back navigation was not confirmed. Say “last page” again.", "phrase": "last page"},
    "tab_left": {"start": "Switching to the tab on the left…", "sent": "Tab left shortcut sent.",
                 "retry": "Tab navigation was not confirmed. Say “tab left” again.", "phrase": "tab left"},
    "tab_right": {"start": "Switching to the tab on the right…", "sent": "Tab right shortcut sent.",
                  "retry": "Tab navigation was not confirmed. Say “tab right” again.", "phrase": "tab right"},
}


NATIVE_EVENTS = frozenset({"ready", "state", "pointer", "speech_start", "speech_cancel", "speech_audio", "targets", "error", "action", "gesture_cancel", "choices_shown", "choices_cancel", "context_changed", "speech_activity", "note_stop"})
WORKER_EVENTS = frozenset({"transcript", "selection", "navigation", "error", "jarvis", "dictation"})


class Coordinator:
    """Bind a recording to its original screen area; never execute voice clicks."""

    def __init__(self, send_native, send_worker, clock=time.monotonic, expiry=20.0):
        self.send_native = send_native
        self.send_worker = send_worker
        self.clock = clock
        self.expiry = expiry
        self.armed = False
        self.voice_ready = True
        self.screen = None
        self.generation = 0
        self.pointer = None
        self.pointer_at = 0.0
        self.pending: Dict[str, Search] = {}
        self.pending_move: Optional[PendingMove] = None
        self.pending_navigation: Optional[PendingNavigation] = None
        self.worker_request = None
        self.deferred_result = None
        self.deferred_until = 0.0
        self.last_pointer = None
        self.notes = Notes(send_native, send_worker, clock)
        self.last_transcript = ""
        self.last_target = ""
        self.region_width = 720
        self.region_height = 420
        self.choices: Optional[Choices] = None
        self.choice_duration = 15.0

    def status(self, message, important=False):
        self.send_native({"type": "status", "message": str(message)[:300], "important": important})

    @staticmethod
    def number(value):
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)

    def invalidate(self, preserve_choices=False):
        """Invalidate results permanently, including after hand reacquisition."""
        self.deferred_result = None
        self.generation += 1
        self.pending.clear()
        self.pending_move = None
        self.pending_navigation = None
        if preserve_choices and self.choices is not None:
            self.choices = replace(self.choices, generation=self.generation)
        else:
            self.clear_choices()

    def clear_choices(self):
        """Hide one exact session; delayed clears cannot hide newer choices."""
        if self.choices is not None:
            choice_id = self.choices.choice_id
            self.choices = None
            self.send_native({"type": "clear_choices", "choice_id": choice_id})

    def _choice_for(self, search):
        choice = self.choices
        if (choice is not None and choice.acknowledged and choice.choice_id == search.choice_id
                and choice.generation == search.generation == self.generation
                and self.clock() < choice.expires_at):
            return choice
        return None

    def _choice_status(self):
        if self.choices is not None:
            self.status(f'Say a number from 1 to {len(self.choices.options)}, or say “cancel”.')

    def _show_choices(self, search, candidate_ids):
        """Number the complete model ambiguity set once, using captured bounds."""
        if (not isinstance(candidate_ids, list) or not 2 <= len(candidate_ids) <= 100
                or any(not isinstance(identifier, str) for identifier in candidate_ids)
                or len(set(candidate_ids)) != len(candidate_ids)):
            return False
        targets = {target["id"]: target for target in search.targets or []}
        if any(identifier not in targets for identifier in candidate_ids):
            return False
        ordered = sorted((targets[identifier] for identifier in candidate_ids),
                         key=lambda target: (target["y"], target["x"], target["id"]))
        options = tuple(ChoiceOption(number=index + 1, **{
            key: target[key] for key in ("id", "label", "x", "y", "width", "height")
        }) for index, target in enumerate(ordered))
        self.choices = Choices(search.request_id, search.generation, search.x, search.y,
                               search.region, self.clock() + self.choice_duration, options)
        self.send_native({"type": "show_choices", "request_id": search.request_id,
                          "choice_id": search.request_id, "duration": self.choice_duration,
                          "options": [option.payload() for option in options]})
        self.status(f'Found {len(options)} matches. Showing numbered choices…')
        return True

    def _revalidate_choices(self, search, targets):
        """Bind each original number to exactly one nearby fresh screen target."""
        choice = self._choice_for(search)
        if choice is None:
            return None
        # Numbers describe the displayed positions, not live element identities.
        return [{"id": option.id, "label": option.label, "x": option.x, "y": option.y,
                 "width": option.width, "height": option.height} for option in choice.options]

    def _discard_capture(self, search, message):
        self.pending.pop(search.request_id, None)
        if search.choice_id is not None:
            self.invalidate(preserve_choices=True)
        self.status(message)

    def set_voice_ready(self, ready):
        self.voice_ready = ready is True
        if not self.voice_ready:
            if self.notes.busy:
                self.notes.inflight = None
                self.notes.queue.clear()
                self.notes.stop("Speech worker stopped; saving the recognized portion")
            self.worker_request = None
            self.invalidate()

    def _region(self, x, y):
        width, height = self.region_width, self.region_height
        if self.screen is None:
            return (x - width / 2, y - height / 2, width, height)
        return self.screen

    @staticmethod
    def request_id(event):
        key = event.get("request_id")
        return key if isinstance(key, str) and 1 <= len(key) <= 100 else None

    def expire(self):
        self.notes.tick()
        now = self.clock()
        if self.pointer is not None and now - self.pointer_at > 0.6:
            self.pointer = None
        if self.deferred_result is not None and now >= self.deferred_until:
            event = self.deferred_result
            self.deferred_result = None
            self.pending.pop(self.request_id(event), None)
            self.status("Speech recognized, but no hand returned within 5 seconds. Show your hand and try again.")
        if self.choices is not None and now >= self.choices.expires_at:
            self.invalidate()
            self.status("Numbered choices expired. Say the target name again.")
        if self.pending_move is not None and now - self.pending_move.started_at >= self.expiry:
            self.pending_move = None
            self.status("Pointer movement was not confirmed. Point and speak again.")
        if self.pending_navigation is not None and now - self.pending_navigation.started_at >= self.expiry:
            message = NAVIGATION_MESSAGES[self.pending_navigation.action]["retry"]
            self.pending_navigation = None
            self.status(message)
        for key, search in list(self.pending.items()):
            if now - search.started_at > self.expiry:
                self._discard_capture(search, "Search expired. Point at the area and speak again.")

    def handle(self, event, source=None):
        if not isinstance(event, dict):
            return
        kind = event.get("type")
        if source is not None:
            allowed = NATIVE_EVENTS if source == "native" else WORKER_EVENTS if source == "worker" else ()
            if kind not in allowed:
                return
        # Audio activity can keep the event queue busy indefinitely; dictation
        # deadlines must advance even when no idle poll or pointer update occurs.
        self.notes.tick()
        if self.notes.observe(event, source):
            return
        if kind == "jarvis" and source == "worker":
            key = self.request_id(event)
            search = self.pending.get(key)
            if key == self.worker_request:
                self.worker_request = None
            if search is not None and search.submitted and self.armed and wake_text(event.get("text")) is not None:
                self.invalidate()
                self.notes.begin(key, event["text"])
            return
        self.expire()
        if (kind == "selection" and source in (None, "worker")) or (kind == "navigation" and source == "worker"):
            search = self.pending.get(self.request_id(event))
            if (search is not None and search.submitted and self.armed and search.generation == self.generation
                    and (self.pointer is None or self.clock() - self.pointer_at > 0.6)):
                if self.worker_request == search.request_id:
                    self.worker_request = None
                if self.deferred_result is None:
                    self.deferred_until = min(search.started_at + self.expiry, self.clock() + 5)
                self.deferred_result = dict(event)
                self.status("Waiting for your hand (up to 5 seconds).")
                return
        if kind == "ready":
            values = (event.get("screen_x", 0), event.get("screen_y", 0),
                      event.get("screen_width"), event.get("screen_height"))
            if all(self.number(value) for value in values) and values[2] > 0 and values[3] > 0:
                self.screen = values
        elif kind == "state":
            armed = event.get("armed") is True
            if armed != self.armed:
                self.invalidate()
            self.armed = armed
        elif kind == "pointer":
            if event.get("tracked") is True and all(self.number(event.get(k)) for k in ("x", "y")):
                self.pointer = (event["x"], event["y"])
                self.pointer_at = self.clock()
                self.last_pointer = self.pointer
                if self.deferred_result is not None:
                    result = self.deferred_result
                    self.deferred_result = None
                    self.handle(result, source="worker")
            else:
                self.pointer = None
        elif kind == "action":
            if event.get("source") == "gesture":
                # Clicks and Mission Control can change the visible context
                # while screen discovery/model work is still in flight.
                self.invalidate()
            elif event.get("source") == "voice" and event.get("action") == "move_to":
                move = self.pending_move
                if (move is not None and self.request_id(event) == move.request_id
                        and move.generation == self.generation and self.armed):
                    self.pending_move = None
                    self.last_target = move.label
                    self.status(f'Target: {move.label}. Pinch middle / ring finger to click.')
            elif event.get("source") == "voice":
                navigation = self.pending_navigation
                if (navigation is not None and self.request_id(event) == navigation.request_id
                        and event.get("action") == navigation.action
                        and navigation.generation == self.generation and self.armed):
                    self.pending_navigation = None
                    self.status(NAVIGATION_MESSAGES[navigation.action]["sent"])
        elif kind == "gesture_cancel":
            # Pinch preparation is not a click. Native waits for its release
            # before applying a result; speech and the displayed choices survive.
            pass
        elif kind == "context_changed":
            self.invalidate()
            self.status("Context changed by a click or app switch. Speak again in the new context.")
        elif kind == "choices_shown":
            if self.choices is not None and event.get("choice_id") == self.choices.choice_id:
                self.choices = replace(self.choices, acknowledged=True)
                self._choice_status()
        elif kind == "choices_cancel":
            if self.choices is not None and event.get("choice_id") == self.choices.choice_id:
                self.invalidate()
                self.status("Numbered choices cleared. Say the target name again.")
        elif kind == "speech_start":
            key = self.request_id(event)
            if (not self.voice_ready or not self.armed or (self.last_pointer is None and self.screen is None)
                    or not isinstance(key, str) or not key or len(key) > 100):
                return
            # One search at a time; speech never queues up delayed mouse actions.
            if self.pending or self.worker_request is not None:
                self.status("Finishing the current search; please speak again afterwards.")
                return
            choice = self.choices
            if choice is not None and not choice.acknowledged:
                self.status("Wait for the numbered circles, then say a number.")
                return
            # A later search owns the status even if an earlier native move
            # finishes asynchronously while its screen check is in flight.
            self.pending_move = None
            self.pending_navigation = None
            x, y = (choice.x, choice.y) if choice is not None else (self.pointer or self.last_pointer or
                (self.screen[0] + self.screen[2] / 2, self.screen[1] + self.screen[3] / 2))
            region = choice.region if choice is not None else self._region(x, y)
            self.pending[key] = Search(key, self.generation, x, y, self.clock(), region,
                                       choice_id=choice.choice_id if choice is not None else None)
            command = {"type": "capture_targets", "request_id": key, "x": x, "y": y,
                       "width": region[2], "height": region[3]}
            if choice is not None:
                command["choice_id"] = choice.choice_id
                self.status("Listening for a number — checking the same targets…")
            else:
                self.status("Listening — searching the screen…")
            self.send_native(command)
        elif kind == "speech_cancel":
            search = self.pending.pop(self.request_id(event), None)
            if search is not None and search.choice_id is not None:
                self.invalidate(preserve_choices=True)
        elif kind in ("targets", "speech_audio"):
            search = self.pending.get(self.request_id(event))
            if search is None or search.generation != self.generation:
                return
            if kind == "targets":
                targets = event.get("targets")
                if not isinstance(targets, list) or len(targets) > 100:
                    self._discard_capture(search, "Screen text was invalid; please try a smaller area.")
                    return
                region = event.get("region")
                if region is not None:
                    # Native reports its clamped crop. It must describe our expected area.
                    values = tuple(region.get(k) for k in ("x", "y", "width", "height")) if isinstance(region, dict) else ()
                    if (len(values) != 4 or not all(self.number(v) for v in values)
                            or any(abs(a - b) > 1 for a, b in zip(values, search.region))):
                        self._discard_capture(search, "Screen area changed; point and speak again.")
                        return
                left, top, width, height = search.region
                valid = []
                seen = set()
                for target in targets:
                    if (not isinstance(target, dict) or not isinstance(target.get("id"), str)
                            or not 1 <= len(target["id"]) <= 120
                            or not isinstance(target.get("label"), str) or not target["label"].strip()
                            or target["id"] in seen or len(target["label"]) > 300
                            or not all(self.number(target.get(k)) for k in ("x", "y", "width", "height"))
                            or target["width"] <= 0 or target["height"] <= 0):
                        continue
                    # Only candidates from the originally requested screen area.
                    if not left - 1 <= target["x"] <= left + width + 1:
                        continue
                    if not top - 1 <= target["y"] <= top + height + 1:
                        continue
                    seen.add(target["id"])
                    valid.append(target)
                if not search.submitted:
                    if search.choice_id is not None:
                        valid = self._revalidate_choices(search, valid)
                        if valid is None:
                            self._discard_capture(search, "Targets changed. Say the target name again.")
                            return
                    search.targets = valid
            else:
                encoded = event.get("pcm_base64")
                rate = event.get("sample_rate")
                if (not isinstance(encoded, str) or len(encoded) > 2500000
                        or type(rate) is not int or not 8000 <= rate <= 96000):
                    self._discard_capture(search, "Recording could not be read; please try again.")
                    return
                search.audio = {"pcm_base64": encoded, "sample_rate": int(rate)}
            if search.targets is not None and search.audio is not None and not search.submitted:
                # Explicit navigation commands do not depend on a readable
                # label. Empty captures still need local transcription.
                choice = self._choice_for(search) if search.choice_id is not None else None
                if search.choice_id is not None and choice is None:
                    self._discard_capture(search, "Numbered choices expired. Say the target name again.")
                    return
                worker_targets = ([{"id": option.id, "label": str(option.number)} for option in choice.options]
                                  if choice is not None else search.targets)
                search.submitted = True
                self.worker_request = search.request_id
                self.status("Argmax is transcribing your number…" if choice is not None else
                            "Argmax is transcribing; Bonsai will match the visible text…")
                try:
                    self.send_worker({"type": "choose" if choice is not None else "search",
                                      "request_id": search.request_id,
                                      "targets": worker_targets, **search.audio})
                except (OSError, RuntimeError):
                    self.set_voice_ready(False)
                    self.status("Speech worker stopped. Restart the app to use voice targeting.", important=True)
        elif kind == "transcript":
            if self.request_id(event) in self.pending:
                self.last_transcript = str(event.get("text", ""))[:300]
                self.status(f'Heard: {self.last_transcript} — locating target…')
                search = self.pending[self.request_id(event)]
                if (source == "worker" and search.submitted and self.armed
                        and search.generation == self.generation and isinstance(event.get("text"), str)
                        and self.last_transcript.strip()):
                    self.send_native({"type": "voice_feedback", "request_id": search.request_id,
                                      "text": self.last_transcript})
        elif kind == "navigation":
            # Navigation is an explicit worker intent, never a model-supplied
            # action or a native event masquerading as recognized speech.
            if source != "worker":
                return
            if self.request_id(event) == self.worker_request:
                self.worker_request = None
            search = self.pending.pop(self.request_id(event), None)
            if (search is None or not search.submitted or not self.armed or search.generation != self.generation
                    or self.pointer is None or self.clock() - self.pointer_at > 0.6):
                return
            action = event.get("action")
            if (not isinstance(action, str) or action not in NAVIGATION_MESSAGES
                    or set(event) != {"type", "request_id", "action"}):
                self.status("Unsupported voice navigation request.")
                return
            choice = self._choice_for(search) if search.choice_id is not None else None
            if search.choice_id is not None and choice is None:
                return
            self.pending_move = None
            self.clear_choices()
            if choice is not None and self.clock() >= choice.expires_at:
                self.status(f'Numbered choices expired. Say “{NAVIGATION_MESSAGES[action]["phrase"]}” again.')
                return
            command = {"type": "voice_action", "action": action, "request_id": search.request_id}
            if search.choice_id is not None:
                command["choice_id"] = search.choice_id
            self.pending_navigation = PendingNavigation(search.request_id, self.generation, action, self.clock())
            self.status(NAVIGATION_MESSAGES[action]["start"])
            self.send_native(command)
        elif kind == "selection":
            if self.request_id(event) == self.worker_request:
                self.worker_request = None
            search = self.pending.pop(self.request_id(event), None)
            if (search is None or not search.submitted or not self.armed or search.generation != self.generation
                    or self.pointer is None or self.clock() - self.pointer_at > 0.6):
                return
            target_id = event.get("target_id")
            if search.choice_id is not None:
                choice = self._choice_for(search)
                if choice is None:
                    return
                if event.get("cancelled") is True:
                    self.invalidate()
                    self.status("Numbered choices cancelled.")
                    return
                if "candidate_ids" in event:
                    self._choice_status()
                    return
            elif "candidate_ids" in event:
                if target_id is not None or not self._show_choices(search, event["candidate_ids"]):
                    self.status("No confident match. Say the visible label again.")
                return
            target = next((t for t in search.targets or [] if t["id"] == target_id), None)
            if target is None:
                if search.choice_id is not None:
                    self._choice_status()
                elif not search.targets:
                    self.status("No named controls or readable text found nearby. Point closer to a label.")
                else:
                    self.status("No confident match. Say the visible label again.")
                return
            command = {"type": "voice_action", "action": "move_to",
                       "request_id": search.request_id, "x": target["x"], "y": target["y"],
                       "label": target["label"]}
            if search.choice_id is not None:
                command["choice_id"] = search.choice_id
                self.clear_choices()
                if self.clock() >= choice.expires_at:
                    self.status("Numbered choices expired. Say the target name again.")
                    return
            self.pending_move = PendingMove(search.request_id, self.generation, target["label"], self.clock())
            self.status(f'Moving to {target["label"]}…')
            self.send_native(command)
        elif kind == "error":
            key = self.request_id(event)
            current_ids = set(self.pending)
            current_ids.update(item.request_id for item in (self.pending_move, self.pending_navigation) if item is not None)
            if key is not None and key not in current_ids:
                if key == self.worker_request:
                    self.worker_request = None
                return  # A cancelled asynchronous operation must not overwrite a newer prompt.
            if self.deferred_result is not None and (key is None or key == self.request_id(self.deferred_result)):
                self.deferred_result = None
            if self.pending_move is not None and (key is None or key == self.pending_move.request_id):
                self.pending_move = None
            if self.pending_navigation is not None and (key is None or key == self.pending_navigation.request_id):
                self.pending_navigation = None
            if key:
                search = self.pending.pop(key, None)
                if search is not None and search.choice_id is not None:
                    self.invalidate(preserve_choices=True)
                if key == self.worker_request:
                    self.worker_request = None
            self.status(str(event.get("message", "Local processing failed.")), important=True)
