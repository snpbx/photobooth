#!/bin/bash
# Copy libgphoto2 + the Canon PTP2 driver into Photobooth.app so the DMG runs
# on a Mac with no Homebrew installed.
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/Photobooth.app"
FW="$APP/Contents/Frameworks"
RES="$APP/Contents/Resources"
GP="$(brew --prefix libgphoto2)"

CAMSRC="$(ls -d "$GP"/lib/libgphoto2/*/ | head -1)"
IOSRC="$(ls -d "$GP"/lib/libgphoto2_port/*/ | head -1)"

rm -rf "$FW" "$RES/camlibs" "$RES/iolibs"
mkdir -p "$FW" "$RES/camlibs" "$RES/iolibs"

# Canon EOS bodies speak PTP2; usb1 is the only port driver a USB booth needs.
cp -L "$CAMSRC/ptp2.so" "$RES/camlibs/ptp2.so"
cp -L "$IOSRC/usb1.so"  "$RES/iolibs/usb1.so"
chmod u+w "$RES/camlibs/ptp2.so" "$RES/iolibs/usb1.so"

is_system() { case "$1" in /usr/lib/*|/System/*) return 0;; *) return 1;; esac }

copy_deps() {
  local f="$1" deps dep base src
  deps=$(otool -L "$f" | awk 'NR>1{print $1}')
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    is_system "$dep" && continue
    base="$(basename "$dep")"
    if [ ! -f "$FW/$base" ]; then
      src="$dep"; [ -f "$src" ] || src="$(brew --prefix)/lib/$base"
      if [ -f "$src" ]; then
        cp -L "$src" "$FW/$base"; chmod u+w "$FW/$base"
        copy_deps "$FW/$base"
      else
        echo "WARN missing dep: $dep"
      fi
    fi
  done <<< "$deps"
}

copy_deps "$APP/Contents/MacOS/Photobooth"
copy_deps "$RES/camlibs/ptp2.so"
copy_deps "$RES/iolibs/usb1.so"

rewrite() {
  local f="$1" prefix="$2" dep base
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    is_system "$dep" && continue
    base="$(basename "$dep")"
    install_name_tool -change "$dep" "$prefix/$base" "$f" 2>/dev/null || true
  done <<< "$(otool -L "$f" | awk 'NR>1{print $1}')"
}

rewrite "$APP/Contents/MacOS/Photobooth" "@executable_path/../Frameworks"
for dy in "$FW"/*.dylib; do
  install_name_tool -id "@rpath/$(basename "$dy")" "$dy" 2>/dev/null || true
  rewrite "$dy" "@loader_path"
done
rewrite "$RES/camlibs/ptp2.so" "@loader_path/../../Frameworks"
rewrite "$RES/iolibs/usb1.so"  "@loader_path/../../Frameworks"

# install_name_tool invalidates signatures, so re-sign every binary we touched.
for b in "$FW"/*.dylib "$RES/camlibs/ptp2.so" "$RES/iolibs/usb1.so"; do
  codesign --force -s - "$b" >/dev/null 2>&1 || true
done

echo "   bundled $(ls "$FW" | wc -l | tr -d ' ') dylibs + ptp2/usb1 drivers"
