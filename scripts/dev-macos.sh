#!/usr/bin/env bash
# Dev build + sign + run of the macOS app WITH iCloud/CloudKit enabled, for testing cross-device
# Send/Continue against the *same* container the iOS app uses. Signs with the Apple Development cert
# (→ CloudKit **Development** environment, matching a debug iOS build) and embeds a macOS development
# provisioning profile — the OS refuses to launch a CloudKit-entitled app without one. NOT for
# distribution; that's release.sh (Developer ID + notarization).
#
# ONE-TIME SETUP (developer.apple.com → Certificates, Identifiers & Profiles):
#   1. Register App ID `com.buildtoberemembered.encore` (macOS, explicit) with the iCloud capability,
#      and assign the existing container `iCloud.com.buildtoberemembered.encore`.
#   2. Register this Mac under Devices (its Provisioning UDID: `system_profiler SPHardwareDataType`).
#   3. Create a "macOS App Development" profile for that App ID + your Apple Development cert + this Mac,
#      download it, and point PROFILE at it (default: ~/Downloads/Encore_macOS_Dev.provisionprofile).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

APP_NAME="Encore"; EXE="emu-window"; BUNDLE_ID="com.buildtoberemembered.encore"
CONTAINER="iCloud.com.buildtoberemembered.encore"; TEAM="JLR4F273N8"
IDENTITY="${SIGN_IDENTITY:-Apple Development: matthieu.coma@pm.me (LGN8ZK8WR6)}"
PROFILE="${PROFILE:-$HOME/Downloads/Encore_macOS_Dev.provisionprofile}"
APP="$ROOT/dist/$APP_NAME.app"
[ -f "$PROFILE" ] || { echo "✗ Provisioning profile not found at: $PROFILE (see setup notes in this script)"; exit 1; }

echo "▸ Building…"; swift build --product "$EXE"

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/debug/$EXE" "$APP/Contents/MacOS/$EXE"
[ -f icon/AppIcon.icns ] && cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R .build/debug/*.bundle "$APP/Contents/Resources/" 2>/dev/null || true
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleExecutable</key><string>$EXE</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>CFBundleVersion</key><string>dev</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

echo "▸ Embedding provisioning profile + signing (Development / CloudKit)…"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
ENT="$(mktemp)"; cat > "$ENT" <<ENTITLE
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.application-identifier</key><string>$TEAM.$BUNDLE_ID</string>
<key>com.apple.developer.team-identifier</key><string>$TEAM</string>
<key>com.apple.developer.icloud-container-identifiers</key><array><string>$CONTAINER</string></array>
<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
<key>com.apple.developer.icloud-container-environment</key><string>Development</string>
</dict></plist>
ENTITLE
codesign --force --entitlements "$ENT" -s "$IDENTITY" "$APP"; rm -f "$ENT"
codesign --verify --strict "$APP" && echo "  signature OK"

echo "▸ Launching…"; open "$APP"
echo "✓ $APP running (CloudKit Development, container $CONTAINER)"
