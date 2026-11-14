"""
Multimodal Contactless HCI Fusion Module.
Coordinates hand gestures (spatial tracking / trigger gating) with Argmax
WhisperKit speech-to-text (semantic actions & parameters) for a cohesive,
contactless human-computer interaction experience.
"""

from dataclasses import dataclass, field
from enum import Enum
import logging
import time
from typing import Any, Callable, Dict, List, Optional, Tuple

from .commands import ContactlessAction, ContactlessCommandParser, ParsedCommand
from .engine import WhisperKitEngine

logger = logging.getLogger("stt.fusion")


class HandGesture(str, Enum):
    """Common recognized hand gestures in contactless interaction."""
    POINT = "POINT"                  # Index finger pointing at target
    PINCH = "PINCH"                  # Index + thumb pinch (often push-to-talk or click)
    OPEN_PALM = "OPEN_PALM"          # Open hand facing camera (stop, cancel, release)
    FIST = "FIST"                    # Closed fist (grab, hold, or voice gate)
    SWIPE_LEFT = "SWIPE_LEFT"        # Fast hand swipe left
    SWIPE_RIGHT = "SWIPE_RIGHT"      # Fast hand swipe right
    SWIPE_UP = "SWIPE_UP"            # Fast hand swipe up
    SWIPE_DOWN = "SWIPE_DOWN"        # Fast hand swipe down
    THUMBS_UP = "THUMBS_UP"          # Confirm / approve
    THUMBS_DOWN = "THUMBS_DOWN"      # Reject / cancel
    NONE = "NONE"                    # No hand detected


@dataclass
class GestureEvent:
    """A hand gesture event received from a gesture detection system (e.g., MediaPipe/OpenCV)."""
    gesture: HandGesture
    x: float = 0.5                   # Normalized screen coordinate [0.0, 1.0]
    y: float = 0.5                   # Normalized screen coordinate [0.0, 1.0]
    confidence: float = 1.0
    timestamp: float = field(default_factory=time.time)
    metadata: Dict[str, Any] = field(default_factory=dict)


@dataclass
class FusedHCIAction:
    """The unified contactless action resulting from fusing hand gesture and voice."""
    action: ContactlessAction
    source: str                      # "VOICE", "GESTURE", or "FUSED"
    coordinates: Optional[Tuple[float, float]] = None
    parameter: Optional[str] = None
    voice_command: Optional[ParsedCommand] = None
    gesture_event: Optional[GestureEvent] = None
    timestamp: float = field(default_factory=time.time)

    def __str__(self) -> str:
        pos_str = f" at ({self.coordinates[0]:.2f}, {self.coordinates[1]:.2f})" if self.coordinates else ""
        param_str = f" ['{self.parameter}']" if self.parameter else ""
        return f"[FUSED ACTION: {self.action.value} via {self.source}]{param_str}{pos_str}"


class GestureVoiceFusionController:
    """
    Coordinates contactless gesture tracking with WhisperKit voice recognition.

    Fusion Strategies:
    1. Gesture-Gated Voice: A hand gesture (e.g., PINCH or FIST) activates the voice
       window; releasing executes the command.
    2. Deictic Resolution: Gesture specifies 'WHERE' (pointing at x, y), while voice
       specifies 'WHAT' ('Select this', 'Zoom in here').
    3. Multimodal Disambiguation: Hand position confirms which UI element receives the voice intent.
    """

    def __init__(
        self,
        engine: Optional[WhisperKitEngine] = None,
        parser: Optional[ContactlessCommandParser] = None,
        on_action: Optional[Callable[[FusedHCIAction], None]] = None,
        spatial_reference_window_sec: float = 2.0,
    ):
        self.engine = engine
        self.parser = parser or ContactlessCommandParser()
        self.on_action = on_action
        self.spatial_reference_window = spatial_reference_window_sec

        # State tracking
        self.last_gesture_event: Optional[GestureEvent] = None
        self.is_voice_gate_active: bool = False
        self.voice_gate_start_time: float = 0.0

    def handle_gesture(self, gesture_event: GestureEvent) -> Optional[FusedHCIAction]:
        """
        Receives hand gesture updates from the vision pipeline (OpenCV / MediaPipe).
        Updates spatial tracking and manages gesture-gated push-to-talk.
        """
        self.last_gesture_event = gesture_event

        # Check for gesture-gated voice triggers (e.g. PINCH or FIST holds open the microphone)
        if gesture_event.gesture in (HandGesture.PINCH, HandGesture.FIST):
            if not self.is_voice_gate_active:
                self.is_voice_gate_active = True
                self.voice_gate_start_time = gesture_event.timestamp
                logger.info(f"Gesture {gesture_event.gesture.value} activated voice listening gate.")
        elif gesture_event.gesture in (HandGesture.OPEN_PALM, HandGesture.NONE):
            if self.is_voice_gate_active:
                self.is_voice_gate_active = False
                logger.info("Voice listening gate closed by hand release.")

        # Map pure gesture shortcuts if no simultaneous voice
        pure_action = None
        if gesture_event.gesture == HandGesture.THUMBS_UP:
            pure_action = ContactlessAction.CONFIRM
        elif gesture_event.gesture == HandGesture.THUMBS_DOWN:
            pure_action = ContactlessAction.CANCEL
        elif gesture_event.gesture == HandGesture.SWIPE_LEFT:
            pure_action = ContactlessAction.GO_BACK
        elif gesture_event.gesture == HandGesture.SWIPE_RIGHT:
            pure_action = ContactlessAction.GO_FORWARD

        if pure_action:
            action = FusedHCIAction(
                action=pure_action,
                source="GESTURE",
                coordinates=(gesture_event.x, gesture_event.y),
                gesture_event=gesture_event,
            )
            self._dispatch(action)
            return action

        return None

    def handle_voice_transcript(self, transcript: str) -> FusedHCIAction:
        """
        Processes a transcript from WhisperKit and fuses it with the active gesture context.
        """
        command = self.parser.parse(transcript)

        # Deictic spatial resolution:
        # If the user speaks a deictic reference ('this', 'here', 'select') and a recent
        # pointing gesture was registered within the spatial reference window,
        # fuse the voice intent with the pointing coordinates.
        coordinates = None
        source = "VOICE"

        if self.last_gesture_event:
            time_delta = time.time() - self.last_gesture_event.timestamp
            if time_delta <= self.spatial_reference_window:
                coordinates = (self.last_gesture_event.x, self.last_gesture_event.y)
                # Check for spatial words in transcript
                raw_lower = command.raw_text.lower()
                if any(w in raw_lower for w in ("this", "here", "there", "target", "select")):
                    source = "FUSED"

        fused = FusedHCIAction(
            action=command.action,
            source=source,
            coordinates=coordinates,
            parameter=command.parameter,
            voice_command=command,
            gesture_event=self.last_gesture_event,
        )

        self._dispatch(fused)
        return fused

    def _dispatch(self, action: FusedHCIAction) -> None:
        """Dispatches fused action to registered callback."""
        if self.on_action:
            try:
                self.on_action(action)
            except Exception as e:
                logger.error(f"Error in on_action callback: {e}")
