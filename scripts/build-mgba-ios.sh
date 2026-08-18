#!/usr/bin/env bash
# Build minimal static libmgba slices for iOS (device + simulator, both arm64) and package them
# as vendor/mgba/mgba.xcframework. Same core-only config as build-mgba.sh (no Qt/SDL/GL/libretro/
# ffmpeg) — the GL renderer is off, so nothing references OpenGL (absent on iOS).
#
# Output:
#   vendor/mgba/build-ios-device/libmgba.a   (arm64, iphoneos)
#   vendor/mgba/build-ios-sim/libmgba.a       (arm64, iphonesimulator)
#   vendor/mgba/mgba.xcframework              (both slices + headers)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/vendor/mgba"
IOS_MIN=18.0

# Locate cmake: pip user install first, then PATH.
PIP_CMAKE="$(python3 -c 'import cmake,os;print(os.path.join(os.path.dirname(cmake.__file__),"data","bin","cmake"))' 2>/dev/null || true)"
if [ -x "$PIP_CMAKE" ]; then
    CMAKE="$PIP_CMAKE"
elif command -v cmake >/dev/null 2>&1; then
    CMAKE="$(command -v cmake)"
else
    echo "error: cmake not found. Install with:  python3 -m pip install --user cmake" >&2
    exit 1
fi
echo "Using cmake: $CMAKE"

# Configure + build one slice.  $1=build dir  $2=sysroot (iphoneos|iphonesimulator)
build_slice() {
    local build="$1" sysroot="$2"
    rm -rf "$build"
    "$CMAKE" -S "$SRC" -B "$build" -G Xcode \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$sysroot" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DBUILD_STATIC=ON -DBUILD_SHARED=OFF \
        -DBUILD_QT=OFF -DBUILD_SDL=OFF -DBUILD_GL=OFF -DBUILD_GLES2=OFF \
        -DBUILD_LIBRETRO=OFF -DBUILD_EXAMPLE=OFF -DBUILD_PERF=OFF -DBUILD_TEST=OFF \
        -DUSE_FFMPEG=OFF -DUSE_MINIZIP=OFF -DUSE_LIBZIP=OFF -DUSE_SQLITE3=OFF \
        -DUSE_ELF=OFF -DUSE_EPOXY=OFF -DUSE_DISCORD_RPC=OFF -DUSE_LZMA=OFF \
        -DUSE_PNG=OFF -DUSE_ZLIB=OFF
    # Build MinSizeRel, not Release: mGBA's APPLE branch force-appends -flto to the *Release*
    # config only, and LTO makes libtool emit an archive of LLVM bitcode (magic 0xb17c0de) that
    # -create-xcframework can't read. MinSizeRel (-Os) sidesteps that and needs no source patch.
    "$CMAKE" --build "$build" --target mgba --config MinSizeRel
    # Normalise the archive location to $build/libmgba.a regardless of generator layout.
    local lib
    lib="$(find "$build" -name 'libmgba.a' -type f | head -1)"
    [ -n "$lib" ] || { echo "error: libmgba.a not produced in $build" >&2; exit 1; }
    cp "$lib" "$build/libmgba.a"
    echo "  -> $build/libmgba.a"
}

DEVICE="$SRC/build-ios-device"
SIM="$SRC/build-ios-sim"

echo "== iOS device slice (arm64, iphoneos) =="
build_slice "$DEVICE" iphoneos
echo "== iOS simulator slice (arm64, iphonesimulator) =="
build_slice "$SIM" iphonesimulator

# Assemble a headers dir the xcframework can carry (public tree + generated flags.h).
HDR="$SRC/build-ios-headers"
rm -rf "$HDR"
mkdir -p "$HDR"
cp -R "$SRC/include/." "$HDR/"
# flags.h is generated during configure; grab it from either slice (identical across slices).
FLAGS="$(find "$DEVICE" "$SIM" -path '*/include/mgba/flags.h' | head -1)"
[ -n "$FLAGS" ] && { mkdir -p "$HDR/mgba"; cp "$FLAGS" "$HDR/mgba/flags.h"; }

XCF="$SRC/mgba.xcframework"
rm -rf "$XCF"
xcodebuild -create-xcframework \
    -library "$DEVICE/libmgba.a" -headers "$HDR" \
    -library "$SIM/libmgba.a" -headers "$HDR" \
    -output "$XCF"

echo
echo "Built xcframework:"
find "$XCF" -name 'libmgba.a' -exec ls -la {} \;
