"""Local microphone transcription using Argmax's streaming CLI."""

from collections import deque
import errno
import logging
import os
import pty
from queue import Empty, Queue
import subprocess
import threading
from typing import Callable, Optional

from .config import STTConfig
from .engine import WhisperKitEngine, _clean_whisper_text
from .runtime import offline_command, offline_environment

logger = logging.getLogger("stt.stream")


class WhisperKitStreamer:
    """Emit confirmed segments once; expose provisional text separately.

    Argmax prints cumulative snapshots, not independent transcript lines.
    Confirmed segments are delivered as plain strings through on_text and
    get_text(). Provisional text may change and is available separately through
    on_partial_text. Callbacks run on the background reader thread.
    """

    def __init__(
        self,
        config: Optional[STTConfig] = None,
        on_text: Optional[Callable[[str], None]] = None,
        on_partial_text: Optional[Callable[[str], None]] = None,
    ):
        self.config = config or STTConfig()
        self.on_text = on_text
        self.on_partial_text = on_partial_text
        self._process = None
        self._thread = None
        self._output = None
        self._stop_event = threading.Event()
        self._text_queue: Queue[str] = Queue()
        self._diagnostics = deque(maxlen=20)
        self._confirmed_count = 0
        self._snapshot_index = 0
        self._partial_segments = []
        self._last_partial = ""

    def is_running(self) -> bool:
        return self._process is not None and (
            self._process.poll() is None or (self._thread is not None and self._thread.is_alive())
        )

    def start(self) -> None:
        if self.is_running():
            return
        if self._process is not None:
            self.stop()
        WhisperKitEngine(self.config)  # Same asset validation as file inference.
        cmd = offline_command(self.config) + ["--stream"]
        self._stop_event.clear()
        self._diagnostics.clear()
        self._text_queue = Queue()
        self._confirmed_count = self._snapshot_index = 0
        self._partial_segments = []
        self._last_partial = ""

        # Swift stdout is block-buffered when piped. A PTY makes live snapshots
        # available immediately. Merging stderr also prevents an undrained pipe
        # from blocking the process when CoreML emits diagnostics.
        master, slave = pty.openpty()
        try:
            self._process = subprocess.Popen(
                cmd, stdin=subprocess.DEVNULL, stdout=slave,
                stderr=subprocess.STDOUT, env=offline_environment(),
            )
        except Exception:
            os.close(master)
            raise
        finally:
            os.close(slave)
        self._output = os.fdopen(master, "r", encoding="utf-8", errors="replace")
        self._thread = threading.Thread(target=self._read_stream, daemon=True)
        self._thread.start()

    @staticmethod
    def _callback(callback, value):
        if callback:
            try:
                callback(value)
            except Exception:
                logger.exception("Speech callback failed")

    def _handle_line(self, line: str) -> None:
        text = line.strip()
        if text == "---":
            self._snapshot_index = 0
            self._partial_segments = []
        elif text.startswith("Confirmed segment:"):
            self._snapshot_index += 1
            if self._snapshot_index <= self._confirmed_count:
                return
            self._confirmed_count = self._snapshot_index
            transcript = _clean_whisper_text(text.partition(":")[2])
            if transcript:
                self._text_queue.put(transcript)
                self._callback(self.on_text, transcript)
        elif text.startswith("Unconfirmed segment:"):
            self._partial_segments.append(_clean_whisper_text(text.partition(":")[2]))
        elif text.startswith("Current text:"):
            current = _clean_whisper_text(text.partition(":")[2])
            partial = " ".join(filter(None, [*self._partial_segments, current]))
            if partial != self._last_partial:
                self._last_partial = partial
                self._callback(self.on_partial_text, partial)
        elif text:
            self._diagnostics.append(text)

    def _read_stream(self) -> None:
        try:
            for line in self._output:
                if self._stop_event.is_set():
                    break
                self._handle_line(line)
        except OSError as error:
            # PTYs on macOS/Linux may report EIO when the child closes its side.
            if error.errno != errno.EIO:
                self._diagnostics.append(str(error))
        finally:
            self._output.close()

    def raise_if_failed(self) -> None:
        """Surface subprocess errors to a caller's event loop."""
        if self._process is not None and not self.is_running():
            code = self._process.poll()
            if code and not self._stop_event.is_set():
                detail = "\n".join(self._diagnostics)
                raise RuntimeError(f"WhisperKit microphone stream exited with code {code}:\n{detail}")

    def stop(self) -> None:
        self._stop_event.set()
        process = self._process
        if process is not None:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if self._thread and self._thread is not threading.current_thread():
            self._thread.join(timeout=3)
        self._process = None
        self._thread = None

    def get_text(self, timeout: Optional[float] = None) -> Optional[str]:
        """Retrieve the next confirmed transcript; return None on timeout.

        Use timeout=0 for nonblocking polling from an application's event loop.
        The original words are preserved, including phrases such as 'scroll down'.
        """
        try:
            return self._text_queue.get(timeout=timeout)
        except Empty:
            self.raise_if_failed()
            return None

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.stop()
