"""
Real-time streaming microphone listener for WhisperKit Argmax models.
Captures live microphone audio using whisperkit-cli and streams
recognized text and contactless commands in real time.
"""

import logging
from queue import Empty, Queue
import subprocess
import threading
import time
from typing import Callable, Optional

from .commands import ContactlessAction, ContactlessCommandParser, ParsedCommand
from .config import STTConfig

logger = logging.getLogger("stt.stream")


class WhisperKitStreamer:
    """
    Continuous microphone listener powered by Argmax WhisperKit.
    Streams live transcriptions and dispatches recognized contactless commands.
    """

    def __init__(
        self,
        config: Optional[STTConfig] = None,
        parser: Optional[ContactlessCommandParser] = None,
        on_text: Optional[Callable[[str], None]] = None,
        on_command: Optional[Callable[[ParsedCommand], None]] = None,
    ):
        self.config = config or STTConfig()
        self.parser = parser or ContactlessCommandParser()
        self.on_text = on_text
        self.on_command = on_command

        self._process: Optional[subprocess.Popen] = None
        self._thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()
        self._event_queue: Queue[ParsedCommand] = Queue()

    def is_running(self) -> bool:
        """Returns True if the streaming listener process is active."""
        return self._process is not None and self._process.poll() is None

    def start(self) -> None:
        """Starts live microphone listening in a background thread."""
        if self.is_running():
            logger.warning("WhisperKitStreamer is already running.")
            return

        if not self.config.is_model_available():
            raise FileNotFoundError(
                f"Argmax model not found at {self.config.model_path}. "
                "Run scripts/setup_models.sh before streaming."
            )

        cmd = [
            self.config.cli_binary,
            "transcribe",
            "--model-path", str(self.config.model_path),
            "--download-tokenizer-path", str(self.config.tokenizer_path),
            "--stream",
            "--audio-encoder-compute-units", self.config.audio_encoder_compute_units,
            "--text-decoder-compute-units", self.config.text_decoder_compute_units,
            "--language", self.config.language,
            "--chunking-strategy", self.config.chunking_strategy,
        ]

        logger.info("Starting live microphone stream with Argmax WhisperKit...")
        self._stop_event.clear()
        self._process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,  # Line-buffered
        )

        self._thread = threading.Thread(target=self._read_stream, daemon=True)
        self._thread.start()

    def _read_stream(self) -> None:
        """Internal worker thread reading stdout from whisperkit-cli."""
        if not self._process or not self._process.stdout:
            return

        for line in self._process.stdout:
            if self._stop_event.is_set():
                break

            text = line.strip()
            # Filter out startup or progress logs if any
            if not text or text.startswith("[") or "IOSurface" in text:
                continue

            # Callback for raw text
            if self.on_text:
                try:
                    self.on_text(text)
                except Exception as e:
                    logger.error(f"Error in on_text callback: {e}")

            # Parse into contactless command
            parsed = self.parser.parse(text)
            self._event_queue.put(parsed)

            if self.on_command and parsed.is_known:
                try:
                    self.on_command(parsed)
                except Exception as e:
                    logger.error(f"Error in on_command callback: {e}")

    def stop(self) -> None:
        """Stops the streaming listener and terminates the CLI process."""
        self._stop_event.set()
        if self._process:
            logger.info("Stopping WhisperKit streaming process...")
            self._process.terminate()
            try:
                self._process.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                self._process.kill()
            self._process = None

        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=1.0)
            self._thread = None

    def get_command(self, timeout: Optional[float] = None) -> Optional[ParsedCommand]:
        """Blocking or timed retrieval of the next recognized command."""
        try:
            return self._event_queue.get(timeout=timeout)
        except Empty:
            return None

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.stop()
