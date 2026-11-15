"""Explicit application commands interpreted after local speech transcription."""

from typing import Optional
import unicodedata
import re


def navigation_intent(transcript: str) -> Optional[str]:
    """Recognize the complete requested phrase, never a mention inside speech.

    Argmax only supplies text. This application-level allowlist cannot create
    arbitrary shortcuts or actions from model output or visible screen labels.
    """
    if not isinstance(transcript, str) or len(transcript) > 4000:
        return None
    text = " ".join(unicodedata.normalize("NFKC", transcript).casefold().split())
    text = text.strip(" .!?。，？！")
    text = re.sub(r"^(?:please |(?:can|could|would) you (?:please )?)", "", text)
    text = re.sub(r"(?: please|谢谢)$", "", text).strip()
    if re.fullmatch(r"(?:go |navigate )back(?: to (?:the )?(?:last|previous) page)?|last page|返回上一页|回到上一页", text):
        return "back"
    if text in ("close tab", "close the current tab", "close this tab", "关闭当前标签页"):
        return "close_tab"
    if text in ("alt tab", "alt-tab", "all tab"):
        return "tab_right"
    match = re.fullmatch(r"(?:tab|tap) (left|right)|(?:switch|go|move) to (?:the )?tab (?:on|to) (?:the )?(left|right)", text)
    if match:
        return "tab_" + (match.group(1) or match.group(2))
    return {"切换到左边的标签页": "tab_left", "切换到右边的标签页": "tab_right"}.get(text)
