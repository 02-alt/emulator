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

VERSION="${1:-${VERSION:-1.1.0}}"
BUILD="$(date +%Y%m%d%H%M)"
APP_NAME="Encore"
EXE="emu-window"
BUNDLE_ID="${BUNDLE_ID:-com.buildtoberemembered.encore}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: MATTHIEU FRANCOIS MILO COMALADA (JLR4F273N8)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-emu-notary}"
TEAM="${TEAM:-JLR4F273N8}"
CONTAINER="${CONTAINER:-iCloud.com.buildtoberemembered.encore}"
# For a CloudKit-enabled release, set PROFILE to a **Developer ID** macOS provisioning profile that
# grants the container above (Production). Create it at developer.apple.com → Profiles → "Developer ID"
# for App ID com.buildtoberemembered.encore with the iCloud capability. Leave unset to build without
# iCloud (cross-device Send/Continue disabled). The container's schema must also be Deployed to
# Production in the CloudKit console — see scripts/SHIPPING.md.
PROFILE="${PROFILE:-}"

# Sparkle in-app auto-update. FEED_URL is served as a "latest release" asset so the URL is stable
# across versions; SU_PUBKEY is the EdDSA public key whose private half (in the login keychain) signs
# each update via scripts/make-appcast.sh. Public key is safe to embed.
FEED_URL="${FEED_URL:-https://github.com/02-alt/emulator/releases/latest/download/appcast.xml}"
SU_PUBKEY="${SU_PUBKEY:-F9r6QZCmbCoizKT7BHR94ZM8e7Hp2OLxs8IJiy7zxOU=}"

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
# Sparkle auto-updater framework — the executable's @executable_path/../Frameworks rpath finds it here.
echo "▸ Embedding Sparkle.framework…"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$REL/Sparkle.framework" "$APP/Contents/Frameworks/"

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
    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SU_PUBKEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

echo "▸ Code-signing (Developer ID + hardened runtime)…"
# Sparkle first, bottom-up: re-sign every nested Mach-O (XPC services, the Autoupdate helper, the
# Updater.app, then the framework itself) with our Developer ID + hardened runtime so notarization
# accepts them. The sandboxed Downloader.xpc keeps its own entitlements (--preserve-metadata).
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign -f -o runtime --timestamp --preserve-metadata=entitlements -s "$IDENTITY" "$FW/XPCServices/Downloader.xpc"
codesign -f -o runtime --timestamp -s "$IDENTITY" "$FW/XPCServices/Installer.xpc"
codesign -f -o runtime --timestamp -s "$IDENTITY" "$FW/Autoupdate"
codesign -f -o runtime --timestamp -s "$IDENTITY" "$FW/Updater.app"
codesign -f -o runtime --timestamp -s "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"

# The SwiftPM resource bundles are *shallow* (data only, no Mach-O) — they get sealed as resources
# when the app is signed, so we sign the app itself, not each bundle.
if [ -n "$PROFILE" ] && [ -f "$PROFILE" ]; then
    echo "  + iCloud/CloudKit (Production) via profile: $PROFILE"
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    ENT="$(mktemp)"; cat > "$ENT" <<ENTITLE
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.application-identifier</key><string>$TEAM.$BUNDLE_ID</string>
<key>com.apple.developer.team-identifier</key><string>$TEAM</string>
<key>com.apple.developer.icloud-container-identifiers</key><array><string>$CONTAINER</string></array>
<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
<key>com.apple.developer.icloud-container-environment</key><string>Production</string>
</dict></plist>
ENTITLE
    codesign --force --options runtime --timestamp --entitlements "$ENT" -s "$IDENTITY" "$APP"
    rm -f "$ENT"
else
    echo "  (no PROFILE set → building WITHOUT iCloud; cross-device Send/Continue disabled)"
    codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP"
fi
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
