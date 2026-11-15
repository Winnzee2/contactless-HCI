"""Explicit application commands interpreted after local speech transcription."""

from typing import Optional
import unicodedata


def navigation_intent(transcript: str) -> Optional[str]:
    """Recognize the complete requested phrase, never a mention inside speech.

    Argmax only supplies text. This application-level allowlist cannot create
    arbitrary shortcuts or actions from model output or visible screen labels.
    """
    if not isinstance(transcript, str) or len(transcript) > 4000:
        return None
    text = " ".join(unicodedata.normalize("NFKC", transcript).casefold().split())
    text = text.strip(" .!?。，？！")
    return "back" if text == "last page" else None
