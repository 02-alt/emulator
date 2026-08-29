#!/usr/bin/env bash
# Generate a signed Sparkle appcast for the notarized DMG. Run AFTER release.sh + make-dmg.sh.
#
#   ./scripts/make-appcast.sh [version]
#
# Produces dist/appcast.xml, whose single <item> points at the versioned GitHub Releases asset and
# carries the EdDSA signature (private key from the login keychain — same one whose public half is
# embedded as SUPublicEDKey). Attach BOTH the DMG and appcast.xml to the GitHub release; the app's
# SUFeedURL (…/releases/latest/download/appcast.xml) then always resolves to the newest one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-${VERSION:-}}"
[ -n "$VERSION" ] || { echo "usage: make-appcast.sh <version>" >&2; exit 1; }
APP_NAME="Encore"
REPO="${REPO:-02-alt/emulator}"
DMG="$ROOT/dist/$APP_NAME-$VERSION.dmg"
APP="$ROOT/dist/$APP_NAME.app"

[ -f "$DMG" ] || { echo "Missing $DMG — run scripts/make-dmg.sh first." >&2; exit 1; }
[ -d "$APP" ] || { echo "Missing $APP — run scripts/release.sh first." >&2; exit 1; }

SIGN_TOOL="$(find "$ROOT/.build" -path '*Sparkle/bin/sign_update' -type f 2>/dev/null | head -1)"
[ -x "$SIGN_TOOL" ] || { echo "sign_update not found — run 'swift build' to fetch Sparkle first." >&2; exit 1; }

# sparkle:version must equal the app's CFBundleVersion (Sparkle's newer-than comparison key).
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
# sign_update prints the enclosure attributes directly, e.g.  sparkle:edSignature="…" length="12345"
SIG_ATTRS="$("$SIGN_TOOL" "$DMG")"
URL="https://github.com/$REPO/releases/download/v$VERSION/$APP_NAME-$VERSION.dmg"
PUBDATE="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"

cat > "$ROOT/dist/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>$APP_NAME</title>
    <link>https://github.com/$REPO/releases/latest/download/appcast.xml</link>
    <description>Encore updates</description>
    <language>en</language>
    <item>
      <title>Version $VERSION</title>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <pubDate>$PUBDATE</pubDate>
      <enclosure url="$URL" type="application/octet-stream" $SIG_ATTRS />
    </item>
  </channel>
</rss>
XML

echo "✓ Wrote dist/appcast.xml → version $VERSION (build $BUILD)"
echo "  enclosure: $URL"
