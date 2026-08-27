#!/bin/bash
# Package dist/Photobooth.app into an installable Photobooth.dmg.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Photobooth"
VOL="Photobooth"
APP="dist/$APP_NAME.app"
DMG="dist/$APP_NAME.dmg"
STAGE="build/dmg-stage"

[ -d "$APP" ] || { echo "error: $APP not found — run ./build.sh first"; exit 1; }

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp SETUP.txt "$STAGE/Setup Guide.txt" 2>/dev/null || true

# UDZO = compressed read-only, the normal format for a distributable app disk image.
hdiutil create \
  -volname "$VOL" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG" >/dev/null

rm -rf "$STAGE"

SIZE=$(du -h "$DMG" | cut -f1 | tr -d ' ')
echo "DMG OK → $DMG ($SIZE)"
