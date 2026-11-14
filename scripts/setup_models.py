#!/usr/bin/env python3
"""Explicit online provisioning of Argmax CoreML assets and Whisper tokenizer."""

import argparse
import json
from pathlib import Path
import shutil
import sys
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
from stt import STTConfig, WhisperKitEngine


def download(url: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".part")
    try:
        with urlopen(url, timeout=60) as response, partial.open("wb") as output:
            shutil.copyfileobj(response, output)
            expected_size = response.headers.get("Content-Length")
        if not partial.stat().st_size or (expected_size and partial.stat().st_size != int(expected_size)):
            raise RuntimeError(f"Incomplete download: {url}")
        partial.replace(destination)
    finally:
        partial.unlink(missing_ok=True)


def setup(model: str) -> None:
    config = STTConfig(model_name=model)
    if not config.is_cli_available():
        raise RuntimeError("Install Argmax first: brew install whisperkit-cli")
    repo = "argmaxinc/whisperkit-coreml"
    if not config.is_model_available():
        print(f"Downloading {config.model_name} from {repo}...", flush=True)
        with urlopen(f"https://huggingface.co/api/models/{repo}/revision/main", timeout=60) as response:
            manifest = json.load(response)
        prefix = config.model_name + "/"
        files = [item["rfilename"] for item in manifest["siblings"]
                 if item["rfilename"].startswith(prefix)
                 and (".mlmodelc/" in item["rfilename"] or item["rfilename"].endswith(".json"))]
        if not files:
            raise RuntimeError(f"No CoreML files found for {config.model_name}")
        for name in files:
            relative = Path(name[len(prefix):])
            if relative.is_absolute() or ".." in relative.parts:
                raise RuntimeError("Invalid model asset path")
            print(f"  {relative}", flush=True)
            download(f"https://huggingface.co/{repo}/resolve/{manifest['sha']}/{name}",
                     config.model_path / relative)
    if not config.is_tokenizer_available():
        print(f"Downloading tokenizer {config.tokenizer_name}...", flush=True)
        tokenizer_repo = f"openai/{config.tokenizer_name}"
        with urlopen(f"https://huggingface.co/api/models/{tokenizer_repo}/revision/main", timeout=60) as response:
            revision = json.load(response)["sha"]
        for name in ("tokenizer.json", "tokenizer_config.json", "config.json"):
            download(f"https://huggingface.co/{tokenizer_repo}/resolve/{revision}/{name}",
                     config.tokenizer_path / name)
    if not config.is_offline_ready():
        raise RuntimeError("Incomplete local assets; rerun setup while online.")
    result = WhisperKitEngine(config).transcribe(ROOT / "assets/samples/select_this_item.wav")
    if "select" not in result.text.lower():
        raise RuntimeError(f"Offline smoke test returned unexpected text: {result.text!r}")
    print(f"Offline verified ({model}): {result.text}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=("tiny.en", "base.en", "all"), default="tiny.en")
    args = parser.parse_args()
    try:
        for model in (("tiny.en", "base.en") if args.model == "all" else (args.model,)):
            setup(model)
    except Exception as error:
        print(f"Setup failed: {error}", file=sys.stderr)
        return 1
    print("Setup complete. You can disconnect Wi-Fi and use cli.py transcribe or stream.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
