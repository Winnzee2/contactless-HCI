#!/usr/bin/env bash
# One-time online setup. Inference itself never downloads assets.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v whisperkit-cli >/dev/null && ! command -v argmax-cli >/dev/null; then
    echo "Install Argmax first: brew install whisperkit-cli" >&2
    exit 1
fi
python3 "$SCRIPT_DIR/setup_models.py" "$@"
