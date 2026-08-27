#!/bin/bash
# Render the real SwiftUI screens offscreen at each responsive breakpoint.
# Development aid — not part of the shipped app.
set -euo pipefail
cd "$(dirname "$0")"

OUT="${1:-build/shots}"
shift || true
GP_PREFIX="$(brew --prefix libgphoto2)"
EX_PREFIX="$(brew --prefix libexif)"

mkdir -p build
clang -O2 -fmodules -target arm64-apple-macos14.0 \
  -I"$GP_PREFIX/include" -I"$EX_PREFIX/include" -INative \
  -c Native/gphoto_shim.c -o build/gphoto_shim.o

SRCS=$(ls Sources/*.swift | grep -v 'Sources/main.swift')

swiftc -O -target arm64-apple-macosx14.0 -o build/uishot \
  $SRCS Tools/main.swift build/gphoto_shim.o \
  -import-objc-header Native/gphoto_shim.h \
  -I"$GP_PREFIX/include" -I"$EX_PREFIX/include" \
  -L"$GP_PREFIX/lib" -lgphoto2 -lgphoto2_port -lm \
  -framework AppKit -framework SwiftUI -framework AVFoundation \
  -framework CoreImage -framework CoreText -framework ImageIO

# Scratch config so a screenshot run never disturbs the operator's live settings.
SCRATCH="${TMPDIR:-/tmp}/photobooth-shots-support"
mkdir -p "$SCRATCH"
PHOTOBOOTH_SUPPORT_DIR="$SCRATCH" ./build/uishot "$OUT" "$@"
echo "shots → $OUT"
