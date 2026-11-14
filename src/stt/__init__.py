"""
Offline Argmax WhisperKit speech-to-text on Apple Silicon.
Provides file and microphone transcription as plain text, without interpreting
speech as application commands or performing gesture actions.
"""

from .audio_utils import (
    convert_to_16k_mono_wav,
    generate_synthetic_audio,
    get_audio_info,
    pad_audio_with_silence,
    save_pcm_to_wav,
)
from .config import STTConfig
from .engine import (
    TranscriptionResult,
    TranscriptionSegment,
    WhisperKitEngine,
)
from .stream import WhisperKitStreamer

__all__ = [
    "STTConfig",
    "WhisperKitEngine",
    "TranscriptionResult",
    "TranscriptionSegment",
    "WhisperKitStreamer",
    "get_audio_info",
    "pad_audio_with_silence",
    "convert_to_16k_mono_wav",
    "save_pcm_to_wav",
    "generate_synthetic_audio",
]
