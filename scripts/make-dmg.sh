#!/usr/bin/env bash
# Package the signed+notarized dist/Emu.app into a notarized, stapled Emu-<version>.dmg with a README
# (mirrors the buildtoberemembered DMG format). Run scripts/release.sh first to produce dist/Emu.app.
#
#   ./scripts/make-dmg.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-${VERSION:-1.0.0}}"
APP_NAME="Encore"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: MATTHIEU FRANCOIS MILO COMALADA (JLR4F273N8)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-emu-notary}"

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
STAGE="$DIST/dmg-stage"
DMG="$DIST/$APP_NAME-$VERSION.dmg"

[ -d "$APP" ] || { echo "Missing $APP — run scripts/release.sh first." >&2; exit 1; }

echo "▸ Staging DMG contents…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/README.txt" <<'README'
ENCORE — your Game Boy Advance & PlayStation classics, played again
===================================================================

A clean, native macOS emulator built around a shelf of cartridges and discs:
drop in your own Game Boy Advance ROMs or PlayStation discs, browse them on
the shelf, and play. Save states, battery saves and memory cards, auto-resume,
game-controller support, and RetroAchievements -- all in one small app.

INSTALL
-------
1. Drag "Encore.app" onto the Applications folder in this window.

FIRST LAUNCH
------------
Encore is signed and notarized by Apple, so it just opens -- double-click it.
(If macOS ever hesitates, right-click Encore.app -> Open -> Open, once.)

USING IT
--------
• Add games: drag .gba ROMs or PlayStation discs (.cue/.chd/.pbp) onto the
  shelf, or click + (or press Cmd-O).
• PlayStation: a one-time setup asks for your console's BIOS the first time
  (File -> Set Up PlayStation…). Play with a controller; each game keeps its
  own memory card. An optional hardware renderer (Settings -> Video) upscales
  the 3D on Apple Silicon.
• Browse the shelf: <- / -> (or a controller's D-pad) move; Return / A plays.
• In game: Arrows = D-pad, Z = A, X = B, A = L, S = R, Return = Start,
  Right Shift = Select.  F5 = quicksave, F9 = quickload.
• The game fills the window at its natural 3:2; the controls fade away and
  come back when you move the mouse.
• Controller guide: click both sticks (L3 + R3) -- or press Tab -- to pause and
  bring up the on-screen menu; the D-pad moves, A selects, B goes back.
• RetroAchievements: sign in under Settings -> Achievements to track trophies.

REQUIREMENTS
------------
• Apple Silicon Mac (arm64), macOS 15 or later.
• Your own GBA ROMs / PlayStation discs -- Encore includes no games.
• PlayStation also needs your own console BIOS (dumped from a PS1 you own).

-----------------------------------------------------------------------

Thanks for giving it a spin. Really -- it means a lot. <3

Built with care by buildtoberemembered.

And a quiet thank you to my friends and my brothers -- the ones who
helped me get through life.

And hey -- if you make something, remix it, or just want to share
whatever you're building, come find us on the Discord. We'd love to
see it.

-- buildtoberemembered
README

echo "▸ Building DMG…"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp -s "$IDENTITY" "$DMG"

echo "▸ Notarizing DMG (keychain profile '$NOTARY_PROFILE')…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG" || true

rm -rf "$STAGE"
echo "✓ Done → $DMG"
