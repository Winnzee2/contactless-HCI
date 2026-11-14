"""
Configuration module for Argmax WhisperKit Speech-to-Text.
Manages model paths, hardware compute units, and execution parameters
for fully offline, local inference on Apple Silicon.
"""

from dataclasses import dataclass, field
import os
from pathlib import Path
import shutil
from typing import Optional


@dataclass
class STTConfig:
    """Configuration for local offline WhisperKit speech-to-text inference."""

    # Model identifiers
    # Default to tiny.en for lowest latency (~35ms) on Apple Silicon Neural Engine
    model_name: str = "openai_whisper-tiny.en"
    tokenizer_name: str = "whisper-tiny.en"

    # Base directories
    base_dir: Path = field(default_factory=lambda: Path(__file__).resolve().parent.parent.parent)
    models_dir: Optional[Path] = None

    # Explicit paths (computed automatically if None)
    model_path: Optional[Path] = None
    tokenizer_path: Optional[Path] = None

    # Apple Silicon Compute Units
    # Options: "cpuAndNeuralEngine", "all", "cpuAndGPU", "cpuOnly"
    audio_encoder_compute_units: str = "cpuAndNeuralEngine"
    text_decoder_compute_units: str = "cpuAndNeuralEngine"

    # Transcription parameters
    language: str = "en"
    task: str = "transcribe"  # "transcribe" or "translate"
    temperature: float = 0.0
    chunking_strategy: str = "vad"  # "vad" or "none"
    suppress_special_tokens: bool = True

    # Path to whisperkit-cli binary
    cli_binary: Optional[str] = None

    def __post_init__(self):
        if self.models_dir is None:
            self.models_dir = self.base_dir / "models"

        # Resolve CLI binary
        if self.cli_binary is None:
            detected = shutil.which("whisperkit-cli") or shutil.which("argmax-cli")
            if not detected:
                # Check default Homebrew path on Apple Silicon
                brew_path = Path("/opt/homebrew/bin/whisperkit-cli")
                if brew_path.exists():
                    detected = str(brew_path)
            self.cli_binary = detected

        # Normalize model names
        if self.model_name in ("tiny", "tiny.en", "whisper-tiny.en"):
            self.model_name = "openai_whisper-tiny.en"
            self.tokenizer_name = "whisper-tiny.en"
        elif self.model_name in ("base", "base.en", "whisper-base.en"):
            self.model_name = "openai_whisper-base.en"
            self.tokenizer_name = "whisper-base.en"

        # Resolve model path
        if self.model_path is None:
            self.model_path = self._resolve_model_path()

        # Resolve tokenizer path
        if self.tokenizer_path is None:
            self.tokenizer_path = self._resolve_tokenizer_path()

    def _resolve_model_path(self) -> Path:
        """Find local model directory for fully offline execution."""
        candidates = [
            self.models_dir / "argmaxinc" / "whisperkit-coreml" / self.model_name,
            self.models_dir / "whisperkit-coreml" / self.model_name,
            self.models_dir / self.model_name,
            Path.home() / "Library" / "Caches" / "argmaxinc.whisperkit" / self.model_name,
        ]
        for candidate in candidates:
            if candidate.exists() and (candidate / "AudioEncoder.mlmodelc").exists():
                return candidate

        # Return primary intended path even if not yet downloaded
        return candidates[0]

    def _resolve_tokenizer_path(self) -> Path:
        """Find local tokenizer directory for fully offline execution."""
        candidates = [
            self.models_dir / "openai" / self.tokenizer_name,
            self.models_dir / self.tokenizer_name,
            self.model_path if self.model_path and (self.model_path / "tokenizer.json").exists() else None,
        ]
        for candidate in candidates:
            if candidate and candidate.exists() and (candidate / "tokenizer.json").exists():
                return candidate

        return self.models_dir / "openai" / self.tokenizer_name

    def is_cli_available(self) -> bool:
        """Returns True if whisperkit-cli is found on the system."""
        return self.cli_binary is not None and os.access(self.cli_binary, os.X_OK)

    def is_model_available(self) -> bool:
        """Returns True if the required CoreML model files exist locally."""
        if not self.model_path or not self.model_path.exists():
            return False
        encoder = self.model_path / "AudioEncoder.mlmodelc"
        decoder = self.model_path / "TextDecoder.mlmodelc"
        return encoder.exists() and decoder.exists()

    def is_tokenizer_available(self) -> bool:
        """Returns True if tokenizer files exist locally."""
        if not self.tokenizer_path or not self.tokenizer_path.exists():
            return False
        return (self.tokenizer_path / "tokenizer.json").exists()

    def is_offline_ready(self) -> bool:
        """Returns True if all components are present to run 100% without Wi-Fi."""
        return self.is_cli_available() and self.model_available() and self.is_tokenizer_available()

    # Alias for convenience
    def model_available(self) -> bool:
        return self.is_model_available()
