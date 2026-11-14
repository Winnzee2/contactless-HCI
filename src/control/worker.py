"""JSON-lines worker: Argmax audio -> text -> Bonsai OCR candidate selection."""

import base64
import json
import sys

from stt import STTConfig, WhisperKitEngine
from .bonsai import BonsaiClient, normalize_candidates

MAX_MESSAGE_CHARS = 2600000
MAX_PCM_BYTES = 1600000


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def decode_request(request):
    """Validate the local protocol before spending inference time on a clip."""
    if not isinstance(request, dict) or request.get("type") != "search":
        raise ValueError("Expected a search request")
    if set(request) != {"type", "request_id", "pcm_base64", "sample_rate", "targets"}:
        raise ValueError("Invalid search request fields")
    request_id = request.get("request_id")
    if not isinstance(request_id, str) or not 1 <= len(request_id) <= 100:
        raise ValueError("Invalid search request identifier")
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
    return request_id, audio, rate, targets


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
            result = engine.transcribe_bytes(audio, is_raw_pcm=True, sample_rate=rate)
            emit({"type": "transcript", "request_id": request_id, "text": result.text})
            selection = client.select_target(result.text, targets)
            emit({"type": "selection", "request_id": request_id, "target_id": selection.target_id,
                  "reason": selection.reason})
        except Exception as error:
            emit({"type": "error", "request_id": request_id, "message": str(error)})
    return 0
