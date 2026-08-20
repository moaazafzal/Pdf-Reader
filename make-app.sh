#!/bin/bash
# Builds a universal (Apple Silicon + Intel) AquaPDF.app from the Swift package.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64 --arch x86_64

APP="build/AquaPDF.app"
BIN=".build/apple/Products/Release/AquaPDF"
[ -f "$BIN" ] || BIN=".build/release/AquaPDF"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/AquaPDF"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built: $PWD/$APP"
lipo -info "$APP/Contents/MacOS/AquaPDF"
echo -n "Minimum macOS: "
/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist"
