"""Offline dictation session and bounded audio queue, independent of screen targets."""
from collections import OrderedDict, deque
import re
import uuid

_WAKE = re.compile(r"^\s*hey[\s,!.:;-]+jarvis\b[\s,!.:;-]*", re.I)
_BYE = re.compile(r"\b(?:bye|goodbye)[\s,!.:;-]+jarvis\b[\s,!.:;-]*|\b(?:buy|by)[\s,!.:;-]+jarvis[\s,!.:;-]*$", re.I)


def wake_text(text):
    match = _WAKE.match(text) if isinstance(text, str) else None
    return text[match.end():].strip() if match else None


def note_text(text):
    match = _BYE.search(text)
    return (text[:match.start()].strip(), True) if match else (text.strip(), False)


class Notes:
    def __init__(self, native, worker, clock):
        self.native, self.worker, self.clock = native, worker, clock
        self.recent = OrderedDict()
        self.last_activity = clock()
        self.session = None
        self.accepting = False
        self.queue = deque()
        self.inflight = None
        self.started = 0
        self.parts = []
        self.reason = ""

    @property
    def busy(self):
        return self.session is not None

    def update(self, final=False):
        self.native({"type": "note_update", "session_id": self.session,
                     "text": "\n".join(self.parts), "recording": self.accepting,
                     "final": final, "message": self.reason or "Listening · say Bye Jarvis to finish"})

    def begin(self, request_id, text):
        self.session = uuid.uuid4().hex
        self.parts = []
        self.queue.clear()
        self.accepting = True
        self.reason = ""
        tail, stop = note_text(wake_text(text) or "")
        if tail:
            self.parts.append(tail)
        # Audio recorded while the wake phrase was being transcribed is retained.
        found = False
        for key, audio in self.recent.items():
            if key == request_id:
                found = True
                continue
            if found and audio is not None:
                self.queue.append(audio)
        if not tail and not self.queue:
            self.last_activity = max(self.last_activity, self.clock())
        if stop:
            self.accepting = False
            self.reason = "Stopped by Bye Jarvis"
            self.queue.clear()
        self.update()
        self.tick()

    def observe(self, event, source):
        kind, key = event.get("type"), event.get("request_id")
        if source == "native" and kind == "speech_activity":
            if not self.busy or self.accepting:
                self.last_activity = self.clock()
            return True
        if source == "native" and kind == "speech_start" and isinstance(key, str):
            self.last_activity = self.clock()
            self.recent[key] = None
            while len(self.recent) > 16:
                self.recent.popitem(last=False)
            return self.busy
        if source == "native" and kind == "speech_audio" and key in self.recent:
            audio = {k: event.get(k) for k in ("request_id", "pcm_base64", "sample_rate")}
            # Worker performs full PCM validation; bound queued messages here too.
            if not isinstance(audio["pcm_base64"], str) or len(audio["pcm_base64"]) > 2200000:
                return self.busy
            self.recent[key] = audio
            if self.busy:
                if self.accepting:
                    if len(self.queue) >= 12:
                        self.stop("Transcription could not keep up; saving the captured portion")
                    else:
                        self.queue.append(audio)
                        self.pump()
                return True
        if self.busy and source == "native":
            if kind in ("context_changed", "gesture_cancel", "action", "targets", "speech_cancel"):
                return True
            if kind == "note_stop" or (kind == "state" and event.get("armed") is False):
                self.stop("Recording stopped")
                return kind == "note_stop"
        if self.busy and self.inflight is not None and source == "worker" and key == self.inflight and kind in ("dictation", "error"):
            self.inflight = None
            if kind == "error":
                self.reason = "A speech block failed; saving the recognized portion"
                self.accepting = False
            else:
                text, stop = note_text(str(event.get("text", "")))
                if text:
                    self.parts.append(text)
                if stop:
                    self.accepting = False
                    self.queue.clear()
                    self.reason = "Stopped by Bye Jarvis"
            self.update()
            self.pump()
            return True
        return False

    def stop(self, reason):
        if not self.busy:
            return
        self.accepting = False
        self.reason = reason
        self.update()
        self.pump()

    def tick(self):
        if self.busy and self.accepting and self.clock() - self.last_activity >= 5:
            self.stop("Stopped after 5 seconds of silence")
        if self.inflight and self.clock() - self.started > 45:
            self.inflight = None
            self.queue.clear()
            self.accepting = False
            self.reason = "Transcription timed out; saving the recognized portion"
        self.pump()

    def pump(self):
        if not self.busy or self.inflight:
            return
        if self.queue:
            audio = self.queue.popleft()
            self.inflight = audio["request_id"]
            self.started = self.clock()
            try:
                self.worker({"type": "dictate", "targets": [], **audio})
            except (OSError, RuntimeError):
                self.inflight = None
                self.queue.clear()
                self.accepting = False
                self.reason = "Speech worker unavailable; saving recognized text"
                self.pump()
        elif not self.accepting:
            self.update(final=True)
            self.session = None
            self.recent.clear()
