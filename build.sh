#!/usr/bin/env bash
# Builds build/LiveAspect8.dylib (arm64, iOS) with the stock Xcode toolchain.
# Run on macOS:  bash build.sh
set -euo pipefail

NAME=LiveAspect8
MIN_IOS=14.0

cd "$(dirname "$0")"
mkdir -p build
DYLIB="build/$NAME.dylib"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos -f clang)"

"$CC" \
  -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min="$MIN_IOS" \
  -fno-objc-arc \
  -O2 -Wall -Wno-deprecated-declarations \
  -dynamiclib \
  -install_name "@rpath/$NAME.dylib" \
  -framework Foundation -framework UIKit -framework CoreGraphics \
  -o "$DYLIB" \
  src/Tweak.m

# Ad-hoc sign so the loader accepts it before LiveContainer re-signs.
codesign -f -s - "$DYLIB"

echo "== verify =="
lipo -info "$DYLIB"
[ "$(lipo -archs "$DYLIB")" = "arm64" ] || { echo "expected arm64 only" >&2; exit 1; }
file "$DYLIB" | grep -q "shared library" || { echo "not a dylib" >&2; exit 1; }
otool -L "$DYLIB"
codesign -dv "$DYLIB" 2>&1 | head -5
echo "OK: $DYLIB"
