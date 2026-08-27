#!/bin/bash
# Build Photobooth.app — Swift/SwiftUI front end + libgphoto2 C shim for the Canon USB link.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Photobooth"
VERSION="1.0.0"
BUILD="1"
DIST="dist"
APP="$DIST/$APP_NAME.app"
OBJ="build"

GP_PREFIX="$(brew --prefix libgphoto2)"
EX_PREFIX="$(brew --prefix libexif)"

rm -rf "$APP"
mkdir -p "$OBJ" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ compiling gphoto shim"
clang -O2 -fmodules -target arm64-apple-macos14.0 \
  -I"$GP_PREFIX/include" -I"$EX_PREFIX/include" -INative \
  -c Native/gphoto_shim.c -o "$OBJ/gphoto_shim.o"

echo "→ compiling Swift sources"
swiftc -O \
  -target arm64-apple-macosx14.0 \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  Sources/*.swift "$OBJ/gphoto_shim.o" \
  -import-objc-header Native/gphoto_shim.h \
  -I"$GP_PREFIX/include" -I"$EX_PREFIX/include" \
  -L"$GP_PREFIX/lib" -lgphoto2 -lgphoto2_port -lm \
  -framework AppKit -framework SwiftUI -framework AVFoundation \
  -framework CoreImage -framework CoreText -framework ImageIO

echo "→ writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>        <string>com.seanamador.photobooth</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>           <string>$BUILD</string>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSCameraUsageDescription</key>
  <string>Photobooth uses a connected camera to take guest photographs.</string>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>Photobooth saves guest photographs to your Pictures folder.</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>Photobooth watches for the USB start button so guests can begin a session while another window has focus.</string>
  <key>NSPrincipalClass</key>          <string>NSApplication</string>
  <key>LSApplicationCategoryType</key> <string>public.app-category.photography</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

./bundle_libs.sh

echo "→ signing"
# A stable identifier keeps the app recognisable to TCC across rebuilds, which
# matters for the Input Monitoring grant the booth button needs.
codesign --force --deep -s - -i com.seanamador.photobooth "$APP" >/dev/null 2>&1 || true

echo "BUILD OK → $APP"
