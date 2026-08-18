#!/usr/bin/env bash
# Build a minimal static libmgba.a (core only — no Qt/SDL/GL/libretro/ffmpeg) for arm64 macOS.
# Output: vendor/mgba/build/libmgba.a  + headers under vendor/mgba/include
#
# CMake is not assumed to be on PATH. We prefer the pip-installed cmake (user space) and fall
# back to any cmake on PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/vendor/mgba"
BUILD="$SRC/build"

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

"$CMAKE" -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_STATIC=ON -DBUILD_SHARED=OFF \
    -DBUILD_QT=OFF -DBUILD_SDL=OFF -DBUILD_GL=OFF -DBUILD_GLES2=OFF \
    -DBUILD_LIBRETRO=OFF -DBUILD_EXAMPLE=OFF -DBUILD_PERF=OFF -DBUILD_TEST=OFF \
    -DUSE_FFMPEG=OFF -DUSE_MINIZIP=OFF -DUSE_LIBZIP=OFF -DUSE_SQLITE3=OFF \
    -DUSE_ELF=OFF -DUSE_EPOXY=OFF -DUSE_DISCORD_RPC=OFF -DUSE_LZMA=OFF \
    -DUSE_PNG=OFF -DUSE_ZLIB=OFF

"$CMAKE" --build "$BUILD" --target mgba -j "$(sysctl -n hw.ncpu)"

echo
echo "Built:"
ls -la "$BUILD"/libmgba.a 2>/dev/null || find "$BUILD" -name 'libmgba*.a' -maxdepth 2
