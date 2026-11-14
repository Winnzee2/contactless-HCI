#!/usr/bin/env bash
# ==============================================================================
# Offline Verification Test Script
# Tests model loading and audio transcription locally.
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "================================================================="
echo " Running Local Offline Verification"
echo "================================================================="

# 1. Run environment health check
python3 "$PROJECT_ROOT/cli.py" check

# 2. Run unit tests
echo ""
echo "[+] Running unit tests..."
python3 -m unittest discover "$PROJECT_ROOT/tests"

# 3. Test offline transcription on sample audio
echo ""
echo "[+] Running local transcription test (no Wi-Fi required)..."
python3 "$PROJECT_ROOT/cli.py" transcribe "$PROJECT_ROOT/assets/samples/select_this_item.wav"

echo ""
echo "[✓] Offline speech-to-text verification passed successfully!"
echo "================================================================="
