#!/usr/bin/env bash
# Build the native camera/mouse helper from Apple's local SDKs. No downloads.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build"
APP="$BUILD/LocalControl.app"
mkdir -p "$APP/Contents/MacOS" "$BUILD/module-cache"
export CLANG_MODULE_CACHE_PATH="$BUILD/module-cache"
# Some upgraded Command Line Tools installations retain an obsolete duplicate
# SwiftBridging module map. Hide only that duplicate in the compiler's virtual
# filesystem; never modify the system toolchain.
TOOLCHAIN="$(dirname "$(dirname "$(xcrun --find swiftc)")")"
OVERLAY_ARGS=()
if [[ -f "$TOOLCHAIN/include/swift/module.modulemap" && -f "$TOOLCHAIN/include/swift/bridging.modulemap" ]]; then
    python3 - "$TOOLCHAIN/include/swift/module.modulemap" "$BUILD" <<'PY_OVERLAY'
import json, sys
from pathlib import Path
source, build = sys.argv[1], Path(sys.argv[2])
empty = build / "empty-swift.modulemap"
empty.write_text("// Obsolete duplicate hidden for this build only.\n")
overlay = {"version": 0, "roots": [{"type": "file", "name": source, "external-contents": str(empty)}]}
(build / "swift-overlay.json").write_text(json.dumps(overlay))
PY_OVERLAY
    OVERLAY_ARGS=(-vfsoverlay "$BUILD/swift-overlay.json" -Xcc -ivfsoverlay -Xcc "$BUILD/swift-overlay.json")
fi
xcrun swiftc "${OVERLAY_ARGS[@]}" -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" -O -module-cache-path "$BUILD/module-cache" \
  -framework AppKit -framework AVFoundation -framework Vision -framework ScreenCaptureKit -framework ApplicationServices \
  "$ROOT/native/GestureCamera.swift" "$ROOT/native/ScreenTargets.swift" "$ROOT/native/TargetOverlay.swift" \
  "$ROOT/native/HandGestures.swift" "$ROOT/native/DesktopActions.swift" "$ROOT/native/DuplicateTargetOverlay.swift" -o "$APP/Contents/MacOS/GestureCamera"
cp "$ROOT/native/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP" >&2
printf '%s\n' "$APP/Contents/MacOS/GestureCamera"
