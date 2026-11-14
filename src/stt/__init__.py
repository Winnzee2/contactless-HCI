"""
Argmax WhisperKit Speech-to-Text Module for Contactless HCI.
Provides fully offline on-device speech transcription, streaming microphone input,
command parsing, and multimodal hand-gesture fusion on Apple Silicon.
"""

from .audio_utils import (
    convert_to_16k_mono_wav,
    generate_synthetic_audio,
    get_audio_info,
    pad_audio_with_silence,
    save_pcm_to_wav,
)
from .commands import (
    ContactlessAction,
    ContactlessCommandParser,
    ParsedCommand,
)
from .config import STTConfig
from .engine import (
    TranscriptionResult,
    TranscriptionSegment,
    WhisperKitEngine,
)
from .fusion import (
    FusedHCIAction,
    GestureEvent,
    GestureVoiceFusionController,
    HandGesture,
)
from .stream import WhisperKitStreamer

__all__ = [
    "STTConfig",
    "WhisperKitEngine",
    "TranscriptionResult",
    "TranscriptionSegment",
    "ContactlessAction",
    "ContactlessCommandParser",
    "ParsedCommand",
    "WhisperKitStreamer",
    "GestureVoiceFusionController",
    "HandGesture",
    "GestureEvent",
    "FusedHCIAction",
    "get_audio_info",
    "pad_audio_with_silence",
    "convert_to_16k_mono_wav",
    "save_pcm_to_wav",
    "generate_synthetic_audio",
]
