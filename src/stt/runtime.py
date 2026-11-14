"""Shared local-only invocation of the macOS Argmax CLI."""

from pathlib import Path
import os

from .config import STTConfig


def offline_command(config: STTConfig) -> list[str]:
    # WhisperKit can try the Hub again if local tokenizer loading fails. Deny
    # networking at the OS boundary, including for child processes, instead of
    # relying on environment variables that Swift libraries may not honor.
    sandbox = Path("/usr/bin/sandbox-exec")
    if not sandbox.is_file():
        raise RuntimeError("Offline inference requires macOS sandbox-exec.")
    cmd = [
        str(sandbox), "-p", "(version 1)(allow default)(deny network*)",
        config.cli_binary, "transcribe",
        "--model-path", str(config.model_path),
        "--download-tokenizer-path", str(config.tokenizer_path),
        "--audio-encoder-compute-units", config.audio_encoder_compute_units,
        "--text-decoder-compute-units", config.text_decoder_compute_units,
        "--temperature", str(config.temperature),
        "--task", config.task,
        "--chunking-strategy", config.chunking_strategy,
    ]
    if config.language not in (None, "auto"):
        cmd.extend(["--language", config.language])
    if config.suppress_special_tokens:
        cmd.append("--skip-special-tokens")
    return cmd


def offline_environment() -> dict[str, str]:
    return {**os.environ, "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"}
