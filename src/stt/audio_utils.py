"""
Audio utility functions for speech-to-text processing.
Handles audio inspection, format normalization (16kHz mono WAV),
silence padding for short recordings, and PCM conversions.
"""

import math
import os
from pathlib import Path
import struct
import subprocess
from typing import Optional, Tuple
import wave


def get_audio_info(audio_path: Path) -> dict:
    """Reads basic audio header info using Python's standard wave module."""
    audio_path = Path(audio_path)
    if not audio_path.exists():
        raise FileNotFoundError(f"Audio file not found: {audio_path}")

    try:
        with wave.open(str(audio_path), "rb") as w:
            frames = w.getnframes()
            rate = w.getframerate()
            channels = w.getnchannels()
            sampwidth = w.getsampwidth()
            duration = frames / float(rate) if rate > 0 else 0.0
            return {
                "format": "WAV",
                "sample_rate": rate,
                "channels": channels,
                "sample_width": sampwidth,
                "duration": duration,
                "frames": frames,
            }
    except Exception:
        # Fallback to macOS afinfo command if available
        try:
            res = subprocess.run(["afinfo", str(audio_path)], capture_output=True, text=True, check=True)
            lines = res.stdout.splitlines()
            duration = 0.0
            for line in lines:
                if "estimated duration:" in line:
                    duration = float(line.split(":")[1].replace("sec", "").strip())
            return {"format": "CoreAudio", "duration": duration, "raw_info": res.stdout}
        except Exception as e:
            return {"error": str(e), "path": str(audio_path)}


def pad_audio_with_silence(
    input_path: Path,
    output_path: Optional[Path] = None,
    lead_silence_sec: float = 0.3,
    tail_silence_sec: float = 0.3,
) -> Path:
    """
    Adds silence padding to short voice clips (< 1.5s).
    Leading and trailing silence can help Whisper handle brief utterances.
    """
    input_path = Path(input_path)
    if output_path is None:
        output_path = input_path.with_name(f"{input_path.stem}_padded.wav")
    else:
        output_path = Path(output_path)

    with wave.open(str(input_path), "rb") as r:
        params = r.getparams()
        frames = r.readframes(r.getnframes())

    bytes_per_sample = params.sampwidth * params.nchannels
    lead_bytes = int(params.framerate * lead_silence_sec) * bytes_per_sample
    tail_bytes = int(params.framerate * tail_silence_sec) * bytes_per_sample

    lead_silence = b"\x00" * lead_bytes
    tail_silence = b"\x00" * tail_bytes

    with wave.open(str(output_path), "wb") as w:
        w.setparams(params)
        w.writeframes(lead_silence + frames + tail_silence)

    return output_path


def convert_to_16k_mono_wav(input_path: Path, output_path: Optional[Path] = None) -> Path:
    """
    Converts arbitrary audio (.m4a, .mp3, .aiff, stereo WAV) to 16kHz mono WAV
    using macOS built-in afconvert.
    """
    input_path = Path(input_path)
    if output_path is None:
        output_path = input_path.with_suffix(".16k.wav")
    else:
        output_path = Path(output_path)

    # Use native macOS afconvert
    cmd = [
        "afconvert",
        "-f", "WAVE",
        "-d", "LEI16@16000",
        "-c", "1",
        str(input_path),
        str(output_path),
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"afconvert failed: {res.stderr}")

    return output_path


def save_pcm_to_wav(
    pcm_bytes: bytes,
    output_path: Path,
    sample_rate: int = 16000,
    channels: int = 1,
    sample_width: int = 2,
) -> Path:
    """Writes raw 16-bit linear PCM byte buffer to a WAV file."""
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(output_path), "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(sample_width)
        w.setframerate(sample_rate)
        w.writeframes(pcm_bytes)
    return output_path


def generate_synthetic_audio(
    output_path: Path,
    duration_sec: float = 2.0,
    frequency: float = 440.0,
    sample_rate: int = 16000,
) -> Path:
    """Generates a synthetic sine-wave tone for testing offline pipeline."""
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    num_samples = int(sample_rate * duration_sec)

    with wave.open(str(output_path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        for i in range(num_samples):
            # 440Hz tone with basic envelope
            envelope = min(1.0, i / (sample_rate * 0.1), (num_samples - i) / (sample_rate * 0.1))
            val = int(8000 * envelope * math.sin(2 * math.pi * frequency * i / sample_rate))
            w.writeframesraw(struct.pack("<h", val))

    return output_path
