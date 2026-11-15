"""State machine for voice target selection, independent of device access."""

from dataclasses import dataclass
import math
import time
from typing import Dict, Optional


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


NATIVE_EVENTS = frozenset({"ready", "state", "pointer", "speech_start", "speech_cancel", "speech_audio", "targets", "error", "action"})
WORKER_EVENTS = frozenset({"transcript", "selection", "error"})


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
        self.worker_request = None
        self.last_transcript = ""
        self.last_target = ""
        self.region_width = 720
        self.region_height = 420

    def status(self, message, important=False):
        self.send_native({"type": "status", "message": str(message)[:300], "important": important})

    @staticmethod
    def number(value):
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)

    def invalidate(self):
        """Invalidate results permanently, including after hand reacquisition."""
        self.generation += 1
        self.pending.clear()

    def set_voice_ready(self, ready):
        self.voice_ready = ready is True
        if not self.voice_ready:
            self.worker_request = None
            self.invalidate()

    def _region(self, x, y):
        width, height = self.region_width, self.region_height
        if self.screen is None:
            return (x - width / 2, y - height / 2, width, height)
        left, top, screen_width, screen_height = self.screen
        width, height = min(width, screen_width), min(height, screen_height)
        return (max(left, min(x - width / 2, left + screen_width - width)),
                max(top, min(y - height / 2, top + screen_height - height)), width, height)

    @staticmethod
    def request_id(event):
        key = event.get("request_id")
        return key if isinstance(key, str) and 1 <= len(key) <= 100 else None

    def expire(self):
        now = self.clock()
        if self.pointer is not None and now - self.pointer_at > 0.6:
            self.pointer = None
            self.invalidate()
        for key, search in list(self.pending.items()):
            if now - search.started_at > self.expiry:
                del self.pending[key]
                self.status("Search expired. Point at the area and speak again.")

    def handle(self, event, source=None):
        if not isinstance(event, dict):
            return
        kind = event.get("type")
        if source is not None:
            allowed = NATIVE_EVENTS if source == "native" else WORKER_EVENTS if source == "worker" else ()
            if kind not in allowed:
                return
        self.expire()
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
            else:
                self.pointer = None
                self.invalidate()
        elif kind == "action":
            if event.get("source") == "gesture":
                # A click can change the visible page while OCR/model work is in flight.
                self.invalidate()
        elif kind == "speech_start":
            key = self.request_id(event)
            if (not self.voice_ready or not self.armed or self.pointer is None or self.clock() - self.pointer_at > 0.6
                    or not isinstance(key, str) or not key or len(key) > 100):
                return
            # One search at a time; speech never queues up delayed mouse actions.
            if self.pending or self.worker_request is not None:
                self.status("Finishing the current search; please speak again afterwards.")
                return
            x, y = self.pointer
            self.pending[key] = Search(key, self.generation, x, y, self.clock(), self._region(x, y))
            self.status("Listening — searching text near your pointer…")
            self.send_native({"type": "capture_targets", "request_id": key, "x": x, "y": y,
                              "width": self.region_width, "height": self.region_height})
        elif kind == "speech_cancel":
            self.pending.pop(self.request_id(event), None)
        elif kind in ("targets", "speech_audio"):
            search = self.pending.get(self.request_id(event))
            if search is None or search.generation != self.generation:
                return
            if kind == "targets":
                targets = event.get("targets")
                if not isinstance(targets, list) or len(targets) > 100:
                    self.pending.pop(search.request_id, None)
                    self.status("Screen text was invalid; please try a smaller area.")
                    return
                region = event.get("region")
                if region is not None:
                    # Native reports its clamped crop. It must describe our expected area.
                    values = tuple(region.get(k) for k in ("x", "y", "width", "height")) if isinstance(region, dict) else ()
                    if (len(values) != 4 or not all(self.number(v) for v in values)
                            or any(abs(a - b) > 1 for a, b in zip(values, search.region))):
                        self.pending.pop(search.request_id, None)
                        self.status("Screen area changed; point and speak again.")
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
                    search.targets = valid
            else:
                encoded = event.get("pcm_base64")
                rate = event.get("sample_rate")
                if (not isinstance(encoded, str) or len(encoded) > 2500000
                        or type(rate) is not int or not 8000 <= rate <= 96000):
                    self.pending.pop(search.request_id, None)
                    self.status("Recording could not be read; please try again.")
                    return
                search.audio = {"pcm_base64": encoded, "sample_rate": int(rate)}
            if search.targets is not None and search.audio is not None and not search.submitted:
                if not search.targets:
                    self.pending.pop(search.request_id, None)
                    self.status("No named controls or readable text found nearby. Point closer to a label.")
                    return
                search.submitted = True
                self.worker_request = search.request_id
                self.status("Argmax is transcribing; Bonsai will match the visible text…")
                try:
                    self.send_worker({"type": "search", "request_id": search.request_id,
                                      "targets": search.targets, **search.audio})
                except (OSError, RuntimeError):
                    self.set_voice_ready(False)
                    self.status("Speech worker stopped. Restart the app to use voice targeting.", important=True)
        elif kind == "transcript":
            if self.request_id(event) in self.pending:
                self.last_transcript = str(event.get("text", ""))[:300]
                self.status(f'Heard: {self.last_transcript} — locating target…')
        elif kind == "selection":
            if self.request_id(event) == self.worker_request:
                self.worker_request = None
            search = self.pending.pop(self.request_id(event), None)
            if (search is None or not search.submitted or not self.armed or search.generation != self.generation
                    or self.pointer is None or self.clock() - self.pointer_at > 0.6):
                return
            target_id = event.get("target_id")
            target = next((t for t in search.targets or [] if t["id"] == target_id), None)
            if target is None:
                self.status("No confident match. Say the visible label again.")
                return
            self.last_target = target["label"]
            self.send_native({"type": "voice_action", "action": "move_to",
                              "request_id": search.request_id, "x": target["x"], "y": target["y"],
                              "label": target["label"]})
            self.status(f'Target: {target["label"]}. Pinch middle / ring finger to click.')
        elif kind == "error":
            key = self.request_id(event)
            if key:
                self.pending.pop(key, None)
                if key == self.worker_request:
                    self.worker_request = None
            self.status(str(event.get("message", "Local processing failed.")), important=True)
