#!/usr/bin/env bash
# Package a Finder-launchable app for this Mac's already-installed local models.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT/scripts/build_gesture_app.sh"
BUILD="$ROOT/.build"
APP="$BUILD/Jarvis.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="$BUILD/module-cache"
OVERLAY_ARGS=()
if [[ -f "$BUILD/swift-overlay.json" ]]; then
    OVERLAY_ARGS=(-vfsoverlay "$BUILD/swift-overlay.json" -Xcc -ivfsoverlay -Xcc "$BUILD/swift-overlay.json")
fi
xcrun swiftc "${OVERLAY_ARGS[@]}" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -O \
    -module-cache-path "$BUILD/module-cache" -framework AppKit \
    "$ROOT/native/ProductLauncher.swift" -o "$APP/Contents/MacOS/JarvisLauncher"
printf '%s\n' "$ROOT" > "$APP/Contents/Resources/project-root.txt"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Jarvis</string>
<key>CFBundleIdentifier</key><string>local.argmax.control-launcher</string>
<key>CFBundleExecutable</key><string>JarvisLauncher</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSCameraUsageDescription</key><string>Recognize your hand locally to move the pointer. Camera frames stay on this Mac.</string>
<key>NSMicrophoneUsageDescription</key><string>Record short speech clips for local Argmax transcription. Audio stays on this Mac.</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$APP" >&2
printf '\nReady: %s\n' "$APP"
