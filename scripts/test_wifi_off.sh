#!/usr/bin/env bash
# Explicit hardware acceptance: temporarily turn Wi-Fi off, test, restore it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTERFACE="${1:-en0}"
REPORT="$ROOT/.build/verification/wifi-off"
NATIVE="$ROOT/.build/LocalControl.app/Contents/MacOS/GestureCamera"
mkdir -p "$REPORT"
ORIGINAL="$(/usr/sbin/networksetup -getairportpower "$INTERFACE")"
printf '%s\n' "$ORIGINAL" > "$REPORT/wifi-before.txt"
case "$ORIGINAL" in
    *': On') RESTORE_WIFI=1 ;;
    *': Off') RESTORE_WIFI=0 ;;
    *) echo "Unrecognized Wi-Fi state; no settings changed: $ORIGINAL" >&2; exit 1 ;;
esac
restore_wifi() {
    if [[ "$RESTORE_WIFI" == 1 ]]; then
        /usr/sbin/networksetup -setairportpower "$INTERFACE" on
    fi
    /usr/sbin/networksetup -getairportpower "$INTERFACE" > "$REPORT/wifi-after.txt"
}
trap restore_wifi EXIT
trap 'exit 130' INT TERM HUP
if [[ "$RESTORE_WIFI" == 1 ]]; then
    /usr/sbin/networksetup -setairportpower "$INTERFACE" off
fi
OFFLINE_STATE="$(/usr/sbin/networksetup -getairportpower "$INTERFACE")"
printf '%s\n' "$OFFLINE_STATE" > "$REPORT/wifi-during.txt"
[[ "$OFFLINE_STATE" == *': Off' ]] || { echo "Wi-Fi did not turn off; aborting test." >&2; exit 1; }
printf '%s\n' "$OFFLINE_STATE"
"$NATIVE" --check > "$REPORT/permissions.json"
"$NATIVE" --self-test > "$REPORT/native-logic.json"
"$NATIVE" --camera-self-test > "$REPORT/camera.json"
"$NATIVE" --screen-self-test > "$REPORT/screen-ocr.json"
python3 "$ROOT/scripts/test_product_offline.py" --output-dir "$REPORT/pipeline"
python3 - "$REPORT" <<'PY'
import json, sys
from datetime import datetime, timezone
from pathlib import Path
root = Path(sys.argv[1])
report = {'verified_at': datetime.now(timezone.utc).isoformat(),
          'wifi_during': (root/'wifi-during.txt').read_text().strip(),
          'camera': json.loads((root/'camera.json').read_text()),
          'screen_ocr': json.loads((root/'screen-ocr.json').read_text()),
          'pipeline_passed': json.loads((root/'pipeline/offline-pipeline.json').read_text())['passed']}
(root/'summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print('Wi-Fi-off hardware and local model pipeline checks passed.')
print('Evidence:',root)
PY
