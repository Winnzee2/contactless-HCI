"""
Contactless HCI Voice Command Parser.
Maps transcribed speech into structured actions for touchless human-computer interaction.
Supports fuzzy matching, keyword spotting, and parameter extraction (e.g., dictation/search).
"""

from dataclasses import dataclass, field
from difflib import SequenceMatcher
from enum import Enum
import re
from typing import Dict, List, Optional, Tuple


class ContactlessAction(str, Enum):
    # Navigation
    SCROLL_UP = "SCROLL_UP"
    SCROLL_DOWN = "SCROLL_DOWN"
    GO_BACK = "GO_BACK"
    GO_FORWARD = "GO_FORWARD"
    GO_HOME = "GO_HOME"
    PAGE_UP = "PAGE_UP"
    PAGE_DOWN = "PAGE_DOWN"

    # Selection & Interaction
    SELECT = "SELECT"
    CLICK = "CLICK"
    DOUBLE_CLICK = "DOUBLE_CLICK"
    OPEN = "OPEN"
    CLOSE = "CLOSE"

    # Control Flow
    CONFIRM = "CONFIRM"
    CANCEL = "CANCEL"
    PAUSE = "PAUSE"
    RESUME = "RESUME"
    STOP = "STOP"

    # View & Display
    ZOOM_IN = "ZOOM_IN"
    ZOOM_OUT = "ZOOM_OUT"
    RESET_ZOOM = "RESET_ZOOM"
    FULLSCREEN = "FULLSCREEN"

    # Audio & Media
    MUTE = "MUTE"
    UNMUTE = "UNMUTE"
    VOLUME_UP = "VOLUME_UP"
    VOLUME_DOWN = "VOLUME_DOWN"

    # Text & Search
    INPUT_TEXT = "INPUT_TEXT"
    SEARCH = "SEARCH"

    # Multimodal Interaction Modes
    VOICE_MODE = "VOICE_MODE"
    GESTURE_MODE = "GESTURE_MODE"
    HYBRID_MODE = "HYBRID_MODE"

    # Fallback / Info
    HELP = "HELP"
    UNKNOWN = "UNKNOWN"


@dataclass
class ParsedCommand:
    """The result of parsing a voice transcript for contactless HCI."""
    action: ContactlessAction
    raw_text: str
    confidence: float = 1.0
    parameter: Optional[str] = None
    metadata: Dict[str, str] = field(default_factory=dict)

    @property
    def is_known(self) -> bool:
        return self.action != ContactlessAction.UNKNOWN

    def __str__(self) -> str:
        param_str = f" ('{self.parameter}')" if self.parameter else ""
        return f"[{self.action.value}]{param_str} (confidence: {self.confidence:.2f})"


# Canonical trigger phrases for each contactless action
DEFAULT_COMMAND_PATTERNS: Dict[ContactlessAction, List[str]] = {
    ContactlessAction.SCROLL_UP: [
        "scroll up", "scroll upward", "page up", "move up", "go up"
    ],
    ContactlessAction.SCROLL_DOWN: [
        "scroll down", "scroll downward", "page down", "move down", "go down"
    ],
    ContactlessAction.GO_BACK: [
        "go back", "back", "previous", "previous page", "return"
    ],
    ContactlessAction.GO_FORWARD: [
        "go forward", "forward", "next", "next page"
    ],
    ContactlessAction.GO_HOME: [
        "go home", "home", "main menu", "home screen"
    ],
    ContactlessAction.SELECT: [
        "select", "select this", "select item", "choose this", "pick this"
    ],
    ContactlessAction.CLICK: [
        "click", "click here", "tap", "press"
    ],
    ContactlessAction.DOUBLE_CLICK: [
        "double click", "open item"
    ],
    ContactlessAction.OPEN: [
        "open", "open window", "open file", "launch"
    ],
    ContactlessAction.CLOSE: [
        "close", "close window", "exit", "quit"
    ],
    ContactlessAction.CONFIRM: [
        "confirm", "confirm and proceed", "proceed", "yes", "okay", "submit", "accept", "apply"
    ],
    ContactlessAction.CANCEL: [
        "cancel", "no", "dismiss", "abort", "reject", "never mind"
    ],
    ContactlessAction.PAUSE: [
        "pause", "freeze", "hold", "stop listening"
    ],
    ContactlessAction.RESUME: [
        "resume", "play", "unpause", "continue"
    ],
    ContactlessAction.STOP: [
        "stop", "halt"
    ],
    ContactlessAction.ZOOM_IN: [
        "zoom in", "enlarge", "magnify", "closer"
    ],
    ContactlessAction.ZOOM_OUT: [
        "zoom out", "shrink", "minimize view", "further"
    ],
    ContactlessAction.RESET_ZOOM: [
        "reset zoom", "original size", "fit to screen"
    ],
    ContactlessAction.FULLSCREEN: [
        "fullscreen", "full screen", "toggle fullscreen"
    ],
    ContactlessAction.MUTE: [
        "mute", "silence", "mute audio"
    ],
    ContactlessAction.UNMUTE: [
        "unmute", "enable audio"
    ],
    ContactlessAction.VOLUME_UP: [
        "volume up", "louder", "turn up"
    ],
    ContactlessAction.VOLUME_DOWN: [
        "volume down", "quieter", "turn down"
    ],
    ContactlessAction.VOICE_MODE: [
        "voice mode", "voice only"
    ],
    ContactlessAction.GESTURE_MODE: [
        "gesture mode", "gestures only"
    ],
    ContactlessAction.HYBRID_MODE: [
        "hybrid mode", "multimodal mode", "gesture and voice"
    ],
    ContactlessAction.HELP: [
        "help", "show commands", "what can i say", "commands"
    ],
}


class ContactlessCommandParser:
    """
    Parses natural speech transcripts into contactless HCI actions.
    Supports fuzzy matching, polite filler words ('please', 'could you'),
    and parametric command extraction ('type ...', 'search ...').
    """

    def __init__(
        self,
        patterns: Optional[Dict[ContactlessAction, List[str]]] = None,
        fuzzy_threshold: float = 0.72,
    ):
        self.patterns = patterns or DEFAULT_COMMAND_PATTERNS
        self.fuzzy_threshold = fuzzy_threshold
        # Filler words commonly said in conversational interaction
        self._filler_re = re.compile(
            r"\b(please|could you|can you|hey|now|just|would you|system|computer)\b",
            re.IGNORECASE,
        )

    def clean_text(self, text: str) -> str:
        """Normalizes text by removing punctuation, extra spaces, and filler words."""
        # Lowercase
        t = text.lower().strip()
        # Remove punctuation except letters and numbers
        t = re.sub(r"[^\w\s]", "", t)
        # Remove filler words
        t = self._filler_re.sub("", t)
        # Collapse whitespace
        t = re.sub(r"\s+", " ", t).strip()
        return t

    def parse(self, transcript: str) -> ParsedCommand:
        """
        Parses a speech transcript string into a ParsedCommand.

        1. Checks parameterized commands ('type <message>', 'search <query>') preserving parameter casing
        2. Checks exact matches across all patterns
        3. Checks word boundary substring matches (prioritizing longer phrases)
        4. Falls back to fuzzy sequence matching
        """
        raw = transcript.strip()
        if not raw:
            return ParsedCommand(action=ContactlessAction.UNKNOWN, raw_text=raw, confidence=0.0)

        cleaned = self.clean_text(raw)

        # 1. Parameterized: Dictation / Text Input (preserve original parameter casing)
        type_match = re.match(r"^(?:type|input|write|dictate|enter)\s+(.+)$", raw, re.IGNORECASE)
        if type_match:
            param = type_match.group(1).strip()
            return ParsedCommand(
                action=ContactlessAction.INPUT_TEXT,
                raw_text=raw,
                confidence=1.0,
                parameter=param,
            )

        # 2. Parameterized: Search (preserve original parameter casing)
        search_match = re.match(r"^(?:search(?:\s+for)?|find)\s+(.+)$", raw, re.IGNORECASE)
        if search_match:
            param = search_match.group(1).strip()
            return ParsedCommand(
                action=ContactlessAction.SEARCH,
                raw_text=raw,
                confidence=1.0,
                parameter=param,
            )

        # 3. Exact matches first (exact match takes highest precedence)
        for action, phrases in self.patterns.items():
            for phrase in phrases:
                if self.clean_text(phrase) == cleaned:
                    return ParsedCommand(action=action, raw_text=raw, confidence=1.0)

        # 4. Word boundary substring matches, sorted by phrase length descending
        all_phrases: List[Tuple[ContactlessAction, str]] = []
        for action, phrases in self.patterns.items():
            for phrase in phrases:
                all_phrases.append((action, phrase))
        # Sort descending by length so "double click" matches before "click"
        all_phrases.sort(key=lambda item: len(item[1]), reverse=True)

        for action, phrase in all_phrases:
            phrase_clean = self.clean_text(phrase)
            if re.search(rf"\b{re.escape(phrase_clean)}\b", cleaned):
                return ParsedCommand(action=action, raw_text=raw, confidence=0.95)

        # 5. Fuzzy Sequence Matcher
        best_action = ContactlessAction.UNKNOWN
        best_score = 0.0

        for action, phrase in all_phrases:
            phrase_clean = self.clean_text(phrase)
            score = SequenceMatcher(None, cleaned, phrase_clean).ratio()
            if score > best_score:
                best_score = score
                best_action = action

        if best_score >= self.fuzzy_threshold:
            return ParsedCommand(
                action=best_action,
                raw_text=raw,
                confidence=round(best_score, 2),
            )

        return ParsedCommand(
            action=ContactlessAction.UNKNOWN,
            raw_text=raw,
            confidence=round(best_score, 2),
        )

    def list_supported_commands(self) -> Dict[str, List[str]]:
        """Returns all recognized actions and their key trigger phrases."""
        return {action.value: phrases for action, phrases in self.patterns.items()}
