#!/bin/bash
# Regenerate Resources/AppIcon.icns. Only needed when the icon design changes.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build Resources
swiftc -O -target arm64-apple-macosx14.0 -o build/makeicon Tools/makeicon.swift -framework AppKit
./build/makeicon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
echo "ICON OK → Resources/AppIcon.icns"
