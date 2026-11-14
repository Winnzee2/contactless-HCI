"""
Core WhisperKit speech-to-text inference engine using Argmax CoreML models.
Runs completely offline on Apple Silicon (CPU + Apple Neural Engine / GPU).
"""

from dataclasses import dataclass, field
import json
import logging
import os
from pathlib import Path
import subprocess
import tempfile
import time
from typing import Any, Dict, List, Optional, Union

from .audio_utils import get_audio_info, pad_audio_with_silence, save_pcm_to_wav
from .config import STTConfig

logger = logging.getLogger("stt.engine")


@dataclass
class TranscriptionSegment:
    """A segment of transcribed text with timing information."""
    id: int
    text: str
    start: float
    end: float
    avg_logprob: float = 0.0
    no_speech_prob: float = 0.0


@dataclass
class TranscriptionResult:
    """The structured result of an Argmax WhisperKit transcription."""
    text: str
    segments: List[TranscriptionSegment] = field(default_factory=list)
    audio_duration: float = 0.0
    pipeline_duration: float = 0.0
    model_name: str = ""
    language: str = "en"
    raw_report: Optional[Dict[str, Any]] = None

    @property
    def speed_factor(self) -> float:
        """How many times faster than real-time the inference completed."""
        if self.pipeline_duration > 0 and self.audio_duration > 0:
            return round(self.audio_duration / self.pipeline_duration, 2)
        return 0.0

    def __str__(self) -> str:
        return self.text


class WhisperKitEngine:
    """
    Offline Speech-to-Text Engine powered by Argmax's WhisperKit CoreML models.
    Executes inference via whisperkit-cli natively on Apple Silicon.
    """

    def __init__(self, config: Optional[STTConfig] = None):
        self.config = config or STTConfig()
        self._validate_environment()

    def _validate_environment(self) -> None:
        """Validates that whisperkit-cli and local model weights are present."""
        if not self.config.is_cli_available():
            raise RuntimeError(
                "whisperkit-cli binary not found! Please install it via Homebrew:\n"
                "  brew install whisperkit-cli\n"
                "Or check that it is in your system PATH."
            )

        if not self.config.is_model_available():
            raise FileNotFoundError(
                f"Argmax WhisperKit model '{self.config.model_name}' was not found at:\n"
                f"  {self.config.model_path}\n"
                "Run `bash scripts/setup_models.sh` while connected to the internet once "
                "to cache the model files locally for offline use."
            )

        if not self.config.is_tokenizer_available():
            raise FileNotFoundError(
                f"Tokenizer files not found at:\n"
                f"  {self.config.tokenizer_path}\n"
                "Run `bash scripts/setup_models.sh` to download tokenizer assets."
            )

    def health_check(self) -> Dict[str, Any]:
        """Returns diagnostic status of local Argmax STT offline capability."""
        return {
            "cli_binary": self.config.cli_binary,
            "cli_available": self.config.is_cli_available(),
            "model_name": self.config.model_name,
            "model_path": str(self.config.model_path),
            "model_available": self.config.is_model_available(),
            "tokenizer_path": str(self.config.tokenizer_path),
            "tokenizer_available": self.config.is_tokenizer_available(),
            "offline_ready": self.config.is_offline_ready(),
            "encoder_compute_units": self.config.audio_encoder_compute_units,
            "decoder_compute_units": self.config.text_decoder_compute_units,
        }

    def transcribe(
        self,
        audio_path: Union[str, Path],
        auto_pad_short_audio: bool = True,
        detailed: bool = False,
    ) -> TranscriptionResult:
        """
        Transcribes a local audio file using the Argmax WhisperKit model.

        Args:
            audio_path: Path to the audio file (.wav, .m4a, .mp3, etc.)
            auto_pad_short_audio: If True, automatically adds silence padding to clips
                                  shorter than 1.5 seconds to ensure optimal Whisper recognition.
            detailed: If True, writes and parses a JSON execution report with segments and timings.

        Returns:
            TranscriptionResult containing transcribed text and metadata.
        """
        audio_path = Path(audio_path).resolve()
        if not audio_path.exists():
            raise FileNotFoundError(f"Audio file not found: {audio_path}")

        # Check duration and apply padding if necessary for short contactless commands
        actual_input_path = audio_path
        cleanup_padded = False
        try:
            info = get_audio_info(audio_path)
            duration = info.get("duration", 0.0)
            if auto_pad_short_audio and 0.0 < duration < 1.5:
                # Pad short commands (e.g., 'click', 'zoom in', 'scroll')
                temp_padded = tempfile.NamedTemporaryFile(suffix="_padded.wav", delete=False)
                temp_padded.close()
                actual_input_path = pad_audio_with_silence(audio_path, Path(temp_padded.name))
                cleanup_padded = True
        except Exception as e:
            logger.debug(f"Could not inspect audio duration, using original file: {e}")
            duration = 0.0

        # Create temporary directory for report if detailed is requested
        temp_dir = tempfile.mkdtemp(prefix="whisperkit_report_")
        report_file = Path(temp_dir) / f"{actual_input_path.stem}.json"

        cmd = [
            self.config.cli_binary,
            "transcribe",
            "--model-path", str(self.config.model_path),
            "--download-tokenizer-path", str(self.config.tokenizer_path),
            "--audio-path", str(actual_input_path),
            "--audio-encoder-compute-units", self.config.audio_encoder_compute_units,
            "--text-decoder-compute-units", self.config.text_decoder_compute_units,
            "--temperature", str(self.config.temperature),
            "--task", self.config.task,
            "--language", self.config.language,
            "--chunking-strategy", self.config.chunking_strategy,
            "--report",
            "--report-path", temp_dir,
        ]

        start_time = time.perf_counter()
        try:
            res = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                check=False,
            )
            wall_time = time.perf_counter() - start_time

            if res.returncode != 0:
                raise RuntimeError(
                    f"WhisperKit transcription failed with exit code {res.returncode}:\n"
                    f"STDERR: {res.stderr}\n"
                    f"STDOUT: {res.stdout}"
                )

            # Parse report if created
            raw_report = None
            segments: List[TranscriptionSegment] = []
            final_text = res.stdout.strip()
            pipeline_time = wall_time

            if report_file.exists():
                try:
                    with open(report_file, "r", encoding="utf-8") as f:
                        raw_report = json.load(f)
                    final_text = raw_report.get("text", final_text).strip()
                    report_timings = raw_report.get("timings", {})
                    pipeline_time = report_timings.get("fullPipeline", wall_time)
                    if not duration:
                        duration = report_timings.get("inputAudioSeconds", 0.0)

                    for seg in raw_report.get("segments", []):
                        # Clean text inside segment
                        seg_text = seg.get("text", "")
                        # Remove Whisper special tokens if present
                        seg_clean = _clean_whisper_text(seg_text)
                        segments.append(
                            TranscriptionSegment(
                                id=seg.get("id", 0),
                                text=seg_clean,
                                start=seg.get("start", 0.0),
                                end=seg.get("end", 0.0),
                                avg_logprob=seg.get("avgLogprob", 0.0),
                                no_speech_prob=seg.get("noSpeechProb", 0.0),
                            )
                        )
                except Exception as e:
                    logger.warning(f"Failed to parse whisperkit report JSON: {e}")

            # Clean final text of whisper tokens
            final_text = _clean_whisper_text(final_text)

            return TranscriptionResult(
                text=final_text,
                segments=segments,
                audio_duration=duration,
                pipeline_duration=pipeline_time,
                model_name=self.config.model_name,
                language=self.config.language,
                raw_report=raw_report if detailed else None,
            )

        finally:
            # Cleanup temporary report files
            if report_file.exists():
                try:
                    report_file.unlink()
                except OSError:
                    pass
            srt_file = Path(temp_dir) / f"{actual_input_path.stem}.srt"
            if srt_file.exists():
                try:
                    srt_file.unlink()
                except OSError:
                    pass
            try:
                os.rmdir(temp_dir)
            except OSError:
                pass
            if cleanup_padded and actual_input_path.exists():
                try:
                    actual_input_path.unlink()
                except OSError:
                    pass

    def transcribe_bytes(
        self,
        pcm_or_wav_bytes: bytes,
        is_raw_pcm: bool = False,
        sample_rate: int = 16000,
        auto_pad_short_audio: bool = True,
        detailed: bool = False,
    ) -> TranscriptionResult:
        """
        Transcribes audio data directly from a byte buffer (useful for streaming buffers
        or gesture-triggered audio clips captured in memory).
        """
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tf:
            temp_path = Path(tf.name)

        try:
            if is_raw_pcm:
                save_pcm_to_wav(pcm_or_wav_bytes, temp_path, sample_rate=sample_rate)
            else:
                with open(temp_path, "wb") as f:
                    f.write(pcm_or_wav_bytes)

            return self.transcribe(
                temp_path,
                auto_pad_short_audio=auto_pad_short_audio,
                detailed=detailed,
            )
        finally:
            if temp_path.exists():
                try:
                    temp_path.unlink()
                except OSError:
                    pass


def _clean_whisper_text(text: str) -> str:
    """Removes Whisper control tokens (e.g. <|startoftranscript|>, <|0.00|>, etc.)."""
    import re
    cleaned = re.sub(r"<\|.*?\|>", "", text)
    # Strip stray whitespace and line breaks
    return cleaned.strip()
