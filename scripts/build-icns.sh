#!/usr/bin/env bash
# Build a macOS iconset + .icns from a single square source PNG (transparent background).
#
#   ./scripts/build-icns.sh <source.png>
#
# Output (into ./icon):
#   icon/master-1024.png        — 1024 master
#   icon/AppIcon.iconset/       — plain PNG set (for iconutil)
#   icon/AppIcon.appiconset/    — Xcode asset-catalog form + Contents.json
#   icon/AppIcon.icns           — compiled icns
#
set -euo pipefail

SRC="${1:-}"
if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
    echo "usage: $0 <source.png>" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/icon"
ISET="$OUT/AppIcon.iconset"
ASET="$OUT/AppIcon.appiconset"
rm -rf "$ISET" "$ASET"
mkdir -p "$ISET" "$ASET"

sips -z 1024 1024 "$SRC" --out "$OUT/master-1024.png" >/dev/null

# px : filename : size : scale
slots=(
    "16:icon_16x16.png:16x16:1x"
    "32:icon_16x16@2x.png:16x16:2x"
    "32:icon_32x32.png:32x32:1x"
    "64:icon_32x32@2x.png:32x32:2x"
    "128:icon_128x128.png:128x128:1x"
    "256:icon_128x128@2x.png:128x128:2x"
    "256:icon_256x256.png:256x256:1x"
    "512:icon_256x256@2x.png:256x256:2x"
    "512:icon_512x512.png:512x512:1x"
    "1024:icon_512x512@2x.png:512x512:2x"
)

imgs=""
for s in "${slots[@]}"; do
    IFS=":" read -r px name size scale <<< "$s"
    sips -z "$px" "$px" "$SRC" --out "$ISET/$name" >/dev/null
    cp "$ISET/$name" "$ASET/$name"
    imgs="$imgs    { \"idiom\":\"mac\", \"size\":\"$size\", \"scale\":\"$scale\", \"filename\":\"$name\" },\n"
done

printf "{\n  \"images\": [\n${imgs%,\\n}\n  ],\n  \"info\": { \"version\":1, \"author\":\"build-icns\" }\n}\n" \
    > "$ASET/Contents.json"

iconutil -c icns "$ISET" -o "$OUT/AppIcon.icns"
echo "Wrote $OUT (AppIcon.icns + iconset)"
