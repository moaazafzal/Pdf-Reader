#!/bin/bash
# Builds AquaPDF.app (universal) and packages it as a distributable .dmg installer.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="AquaPDF"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
VOL_NAME="$APP_NAME $VERSION"
DMG_PATH="build/${APP_NAME}-${VERSION}.dmg"
STAGE="build/dmg-stage"

# 1. Build the universal app.
./make-app.sh

# 2. Stage the disk-image contents: the app plus a drop target for /Applications.
rm -rf "$STAGE" "$DMG_PATH"
mkdir -p "$STAGE"
cp -R "build/${APP_NAME}.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Short install note visible in the mounted volume.
cat > "$STAGE/READ ME FIRST.txt" <<'NOTE'
Installing AquaPDF
==================

1. Drag AquaPDF onto the Applications folder in this window.
2. Open Applications and RIGHT-CLICK (or Control-click) AquaPDF, then choose "Open".
3. Click "Open" in the dialog that appears.

Step 2 is only needed the first time. It is required because this app is not
signed with a paid Apple Developer certificate, so macOS blocks a normal
double-click on first launch. After opening it once this way, AquaPDF launches
normally forever after.

If macOS says the app "is damaged and can't be opened", run this in Terminal:

    xattr -cr /Applications/AquaPDF.app

That clears the quarantine flag macOS adds to downloaded files.

Requirements: macOS 11 Big Sur or later, Apple Silicon or Intel.
NOTE

# 3. Build a read-only compressed image.
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    -fs HFS+ \
    "$DMG_PATH" >/dev/null

rm -rf "$STAGE"

echo "Built: $PWD/$DMG_PATH"
echo -n "Size: "
du -h "$DMG_PATH" | cut -f1
