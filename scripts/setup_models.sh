#!/usr/bin/env bash
# ==============================================================================
# Setup script for Argmax WhisperKit Offline Models
# Pre-downloads and verifies models so they can run 100% offline without Wi-Fi.
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
MODELS_DIR="$PROJECT_ROOT/models"

echo "================================================================="
echo " Argmax WhisperKit Offline Model Setup"
echo "================================================================="

# 1. Check whisperkit-cli
if ! command -v whisperkit-cli &> /dev/null; then
    echo "[!] whisperkit-cli not found."
    echo "    Installing whisperkit-cli via Homebrew..."
    brew install whisperkit-cli
else
    echo "[✓] whisperkit-cli found: $(which whisperkit-cli)"
fi

mkdir -p "$MODELS_DIR"

# 2. Setup tiny.en (default for high-speed contactless interaction)
TINY_DIR="$MODELS_DIR/argmaxinc/whisperkit-coreml/openai_whisper-tiny.en"
if [ -d "$TINY_DIR" ] && [ -f "$TINY_DIR/AudioEncoder.mlmodelc/model.mil" ]; then
    echo "[✓] openai_whisper-tiny.en is already downloaded locally."
else
    echo "[+] Downloading openai_whisper-tiny.en for offline use..."
    whisperkit-cli transcribe \
        --model tiny.en \
        --download-model-path "$MODELS_DIR" \
        --audio-path "$PROJECT_ROOT/assets/samples/speech_command.wav" > /dev/null 2>&1 || true

    # Flatten nested models/models structure if created by CLI
    if [ -d "$MODELS_DIR/models" ]; then
        cp -R "$MODELS_DIR/models/"* "$MODELS_DIR/"
        rm -rf "$MODELS_DIR/models"
    fi
    echo "[✓] openai_whisper-tiny.en setup complete."
fi

# 3. Setup base.en (optional larger model)
BASE_DIR="$MODELS_DIR/argmaxinc/whisperkit-coreml/openai_whisper-base.en"
if [ -d "$BASE_DIR" ] && [ -f "$BASE_DIR/AudioEncoder.mlmodelc/model.mil" ]; then
    echo "[✓] openai_whisper-base.en is already downloaded locally."
else
    echo "[+] Downloading openai_whisper-base.en for offline use..."
    whisperkit-cli transcribe \
        --model base.en \
        --download-model-path "$MODELS_DIR" \
        --audio-path "$PROJECT_ROOT/assets/samples/speech_command.wav" > /dev/null 2>&1 || true

    if [ -d "$MODELS_DIR/models" ]; then
        cp -R "$MODELS_DIR/models/"* "$MODELS_DIR/"
        rm -rf "$MODELS_DIR/models"
    fi
    echo "[✓] openai_whisper-base.en setup complete."
fi

echo "-----------------------------------------------------------------"
python3 "$PROJECT_ROOT/cli.py" check
echo "================================================================="
echo " Setup complete! The models are cached locally and ready for"
echo " offline speech-to-text without internet or Wi-Fi."
echo "================================================================="
