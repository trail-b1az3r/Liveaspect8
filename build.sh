#!/usr/bin/env bash
# Builds build/<name>.dylib (arm64, iOS) for every tweak below with the stock Xcode toolchain.
# Run on macOS:  bash build.sh
set -euo pipefail

MIN_IOS=14.0

cd "$(dirname "$0")"
mkdir -p build

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos -f clang)"

build() {
  local name="$1" src="$2" out="build/$1.dylib"
  echo "== building $name from $src =="
  "$CC" \
    -arch arm64 \
    -isysroot "$SDK" \
    -miphoneos-version-min="$MIN_IOS" \
    -fno-objc-arc \
    -O2 -Wall -Wno-deprecated-declarations -Werror=return-type \
    -dynamiclib \
    -install_name "@rpath/$name.dylib" \
    -framework Foundation -framework UIKit -framework CoreGraphics \
    -framework QuartzCore -framework AVFoundation \
    -o "$out" \
    "$src"

  # Ad-hoc sign so the loader accepts it before LiveContainer re-signs.
  codesign -f -s - "$out"

  [ "$(lipo -archs "$out")" = "arm64" ] || { echo "$out: expected arm64 only" >&2; exit 1; }
  file "$out" | grep -q "shared library" || { echo "$out: not a dylib" >&2; exit 1; }
  otool -L "$out"
  codesign -dv "$out" 2>&1 | head -3
  echo "OK: $out"
}

build LiveAspect8 src/Tweak.m
build FillTube      src/FillTube.m
