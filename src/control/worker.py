"""Local voice worker: Argmax text, Bonsai target names, and numbered followups."""

import base64
import json
import sys

from stt import STTConfig, WhisperKitEngine
from .bonsai import BonsaiClient, normalize_candidates
from .number_choice import parse_number_choice

MAX_MESSAGE_CHARS = 2600000
MAX_PCM_BYTES = 1600000


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def decode_request(request):
    """Validate the local protocol before spending inference time on a clip."""
    if not isinstance(request, dict) or request.get("type") not in {"search", "choose"}:
        raise ValueError("Expected a search or choose request")
    if set(request) != {"type", "request_id", "pcm_base64", "sample_rate", "targets"}:
        raise ValueError("Invalid voice request fields")
    request_id = request.get("request_id")
    if not isinstance(request_id, str) or not 1 <= len(request_id) <= 100:
        raise ValueError("Invalid voice request identifier")
    encoded = request.get("pcm_base64")
    if not isinstance(encoded, str) or not encoded or len(encoded) > 2200000:
        raise ValueError("Invalid encoded PCM recording")
    audio = base64.b64decode(encoded, validate=True)
    if not audio or len(audio) > MAX_PCM_BYTES or len(audio) % 2:
        raise ValueError("Invalid PCM recording")
    rate = request.get("sample_rate")
    if type(rate) is not int or not 8000 <= rate <= 96000:
        raise ValueError("Invalid audio sample rate")
    # The native recorder caps clips at eight seconds. Allow a small frame margin.
    if len(audio) > (rate * 8 + 2048) * 2:
        raise ValueError("Recording exceeds the voice-targeting duration limit")
    targets = normalize_candidates(request.get("targets"))
    if not targets:
        raise ValueError("No screen text candidates were supplied")
    if request["type"] == "choose" and [target["label"] for target in targets] != [
            str(number) for number in range(1, len(targets) + 1)]:
        raise ValueError("Numbered choices must have consecutive labels from 1")
    return request_id, audio, rate, targets


def pad_number_audio(audio, sample_rate):
    """Keep short spoken digits long enough for WhisperKit to decode a clip.

    A single syllable can remain below one second with ordinary 0.3s padding.
    Add silence only; never repeat speech or substitute a guessed transcript.
    """
    frames = len(audio) // 2
    minimum = int(sample_rate * 1.5)
    if frames >= minimum:
        return audio
    leading = int(sample_rate * 0.3)
    trailing = max(leading, minimum - frames - leading)
    return bytes(leading * 2) + audio + bytes(trailing * 2)


def run(args):
    try:
        engine = WhisperKitEngine(STTConfig(model_name=args.speech_model, language=args.language,
                                            transcription_timeout=30))
        client = BonsaiClient(args.bonsai_url, args.bonsai_model, timeout=15)
        client.check_model()
        emit({"type": "worker_ready"})
    except Exception as error:
        emit({"type": "error", "message": str(error)})
        return 1
    while True:
        line = sys.stdin.readline(MAX_MESSAGE_CHARS + 1)
        if not line:
            break
        request_id = None
        try:
            if len(line) > MAX_MESSAGE_CHARS:
                # A broken protocol stream must not be interpreted as later jobs.
                emit({"type": "error", "message": "Oversized voice request"})
                return 1
            request = json.loads(line)
            key = request.get("request_id") if isinstance(request, dict) else None
            request_id = key if isinstance(key, str) and 1 <= len(key) <= 100 else None
            request_id, audio, rate, targets = decode_request(request)
            if request["type"] == "choose":
                result = engine.transcribe_bytes(pad_number_audio(audio, rate), is_raw_pcm=True,
                                                sample_rate=rate, auto_pad_short_audio=False)
            else:
                result = engine.transcribe_bytes(audio, is_raw_pcm=True, sample_rate=rate)
            emit({"type": "transcript", "request_id": request_id, "text": result.text})
            if request["type"] == "choose":
                choice = parse_number_choice(result.text, len(targets))
                event = {"type": "selection", "request_id": request_id,
                         "target_id": targets[choice.number - 1]["id"] if choice.number else None,
                         "reason": "Numbered target selected" if choice.number else "No valid numbered choice"}
                if choice.cancelled:
                    event.update(cancelled=True, reason="Numbered choice cancelled")
                emit(event)
                continue
            selection = client.select_target(result.text, targets)
            event = {"type": "selection", "request_id": request_id, "target_id": selection.target_id,
                     "reason": selection.reason}
            if selection.candidate_ids:
                event["candidate_ids"] = list(selection.candidate_ids)
            emit(event)
        except Exception as error:
            emit({"type": "error", "request_id": request_id, "message": str(error)})
    return 0
