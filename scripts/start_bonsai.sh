#!/usr/bin/env bash
# Run already-installed Bonsai weights using LM Studio's installed MLX runtime.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BONSAI_MODEL_PATH="${BONSAI_MODEL_PATH:-$HOME/.lmstudio/models/prism-ml/Ternary-Bonsai-2-2B-mlx-2bit}"
if [[ -z "${BONSAI_PYTHON:-}" ]]; then
    BONSAI_PYTHON="$(python3 - <<'PY'
from pathlib import Path
import re
root = Path.home() / '.lmstudio/extensions/backends/vendor/_amphibian'
candidates = list(root.glob('app-mlx-generate-*/bin/python3'))
def order(path):
    match = re.search(r'@(\d+)', str(path))
    return int(match.group(1)) if match else 0
for path in sorted(candidates, key=order, reverse=True):
    packages = path.parent.parent / 'lib'
    if any(packages.glob('python*/site-packages/mlx_vlm/models/prism_hadamard_qwen35')):
        print(path)
        break
PY
)"
fi
if [[ -z "$BONSAI_PYTHON" || ! -x "$BONSAI_PYTHON" ]]; then
    echo "No installed MLX runtime with Bonsai support. Set BONSAI_PYTHON to a compatible Python executable." >&2
    exit 1
fi
if [[ ! -f "$BONSAI_MODEL_PATH/model.safetensors" ]]; then
    echo "Local Bonsai weights missing: $BONSAI_MODEL_PATH. Set BONSAI_MODEL_PATH to the installed pack." >&2
    exit 1
fi
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1 PYTHONDONTWRITEBYTECODE=1
# The service accepts local clients but cannot access the internet.
PROFILE='(version 1)(allow default)(deny network*)(allow network-bind (local ip "localhost:*"))(allow network-inbound (local ip "localhost:*"))(allow network-outbound (remote ip "localhost:*"))'
exec /usr/bin/sandbox-exec -p "$PROFILE" "$BONSAI_PYTHON" "$SCRIPT_DIR/serve_bonsai.py" --model-path "$BONSAI_MODEL_PATH" "$@"
