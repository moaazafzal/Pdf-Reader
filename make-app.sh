#!/bin/bash
# Builds AquaPDF.app from the Swift package.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/AquaPDF.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp .build/release/AquaPDF "$APP/Contents/MacOS/AquaPDF"
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built: $PWD/$APP"
