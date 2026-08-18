#!/usr/bin/env bash
# Build, bundle, sign (Developer ID + hardened runtime), notarize, and staple Emu.app.
#
#   ./scripts/release.sh [version]        # e.g. ./scripts/release.sh 1.0.0
#
# ONE-TIME SETUP — store your notarization credentials in the login keychain (the app-specific
# password NEVER goes in this repo or any file):
#
#   xcrun notarytool store-credentials "emu-notary" \
#     --apple-id "matthieu.coma@pm.me" --team-id "JLR4F273N8" --password "<app-specific-password>"
#
# The app-specific password is created at https://appleid.apple.com → Sign-In and Security →
# App-Specific Passwords. Override any of the vars below with env vars if they differ.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-${VERSION:-1.0.0}}"
BUILD="$(date +%Y%m%d%H%M)"
APP_NAME="Encore"
EXE="emu-window"
BUNDLE_ID="${BUNDLE_ID:-com.buildtoberemembered.encore}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: MATTHIEU FRANCOIS MILO COMALADA (JLR4F273N8)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-emu-notary}"

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
REL=".build/release"

echo "▸ Building release…"
swift build -c release

echo "▸ Assembling $APP_NAME.app  ($VERSION, build $BUILD)…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$REL/$EXE" "$APP/Contents/MacOS/$EXE"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles (fonts, DB, sounds) — Bundle.module finds them via the app's Resources.
cp -R "$REL"/*.bundle "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXE</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>© buildtoberemembered</string>
</dict>
</plist>
PLIST

echo "▸ Code-signing (Developer ID + hardened runtime)…"
# The SwiftPM resource bundles are *shallow* (data only, no Mach-O) — they get sealed as resources
# when the app is signed, so we sign the app itself, not each bundle.
codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "▸ Notarizing (uses keychain profile '$NOTARY_PROFILE' — run the one-time store-credentials first)…"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl -a -t exec -vv "$APP" || true

# Re-zip the stapled app for distribution.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✓ Done → $ZIP"
