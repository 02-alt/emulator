#!/usr/bin/env bash
# Build the Beetle PSX libretro core (software renderer) as an arm64 macOS dylib for the PS1 core.
# Output: vendor/beetle-psx-libretro/mednafen_psx_libretro.dylib
#
# This is a GPL libretro core loaded at runtime (dlopen) by Sources/LibretroBridge — it is a
# separate loadable artifact, never linked into our binary. It is NOT bundled in the repo build;
# run this once to produce the dylib, and release.sh copies it into the .app's Resources.
#
# Renderer: software (no GPU deps). Dynarec: lightrec MIPS JIT by default (needed for full speed;
# the app must carry the com.apple.security.cs.allow-jit entitlement). Pass LIGHTREC=0 to fall back
# to the pure interpreter (slower, but no JIT — useful for debugging a boot issue).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/vendor/beetle-psx-libretro"

if [ ! -d "$SRC" ]; then
    echo "error: $SRC missing. Fetch it first:" >&2
    echo "  git clone --depth 1 https://github.com/libretro/beetle-psx-libretro.git \"$SRC\"" >&2
    exit 1
fi

LIGHTREC="${LIGHTREC:-1}"

echo "Building Beetle PSX (software renderer, HAVE_LIGHTREC=$LIGHTREC) for arm64 macOS..."
make -C "$SRC" platform=osx HAVE_LIGHTREC="$LIGHTREC" -j"$(sysctl -n hw.ncpu)"

DYLIB="$SRC/mednafen_psx_libretro.dylib"
echo
if [ -f "$DYLIB" ]; then
    echo "Built: $DYLIB"
    file "$DYLIB"
else
    echo "error: expected $DYLIB was not produced" >&2
    exit 1
fi
