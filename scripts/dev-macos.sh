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

# Sparkle auto-updater framework — the executable's @executable_path/../Frameworks rpath finds it here.
# Without this the signed bundle dyld-crashes at launch ("Library not loaded: @rpath/Sparkle.framework").
echo "▸ Embedding Sparkle.framework…"
mkdir -p "$APP/Contents/Frameworks"
cp -R ".build/debug/Sparkle.framework" "$APP/Contents/Frameworks/"

# PS1 core (Beetle PSX libretro) — a runtime-loaded dylib the PS1 core dlopen's from Resources.
# Optional: only bundled if it's been built (scripts/build-beetle-psx.sh). GPL — fine for a personal
# dev build; revisit before any sale.
PSX_CORE="vendor/beetle-psx-libretro/mednafen_psx_libretro.dylib"
if [ -f "$PSX_CORE" ]; then
    echo "▸ Bundling PS1 core (Beetle PSX)…"
    cp "$PSX_CORE" "$APP/Contents/Resources/"
fi

# PS1 hardware renderer: the Vulkan core + MoltenVK (Vulkan-on-Metal). Both optional — only bundled if
# built/vendored. libretro_vk loads MoltenVK from @executable_path/../Resources; PSXCore(hardware:)
# dlopen's the _hw core from Resources. Experimental path (Settings ▸ Video ▸ Hardware Renderer).
PSX_CORE_HW="vendor/beetle-psx-libretro/mednafen_psx_hw_libretro.dylib"
if [ -f "$PSX_CORE_HW" ]; then
    echo "▸ Bundling PS1 hardware core (Beetle PSX Vulkan)…"
    cp "$PSX_CORE_HW" "$APP/Contents/Resources/"
fi
MOLTENVK="vendor/moltenvk/libMoltenVK.dylib"
if [ -f "$MOLTENVK" ]; then
    echo "▸ Bundling MoltenVK…"
    cp "$MOLTENVK" "$APP/Contents/Resources/"
fi

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
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
<key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
ENTITLE
# Sign Sparkle bottom-up (every nested Mach-O first, then the framework) so the app's --strict verify
# passes — mirrors release.sh, minus the Developer-ID timestamp (dev signing is offline).
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign -f -o runtime --preserve-metadata=entitlements -s "$IDENTITY" "$FW/XPCServices/Downloader.xpc"
codesign -f -o runtime -s "$IDENTITY" "$FW/XPCServices/Installer.xpc"
codesign -f -o runtime -s "$IDENTITY" "$FW/Autoupdate"
codesign -f -o runtime -s "$IDENTITY" "$FW/Updater.app"
codesign -f -o runtime -s "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"

# Sign the bundled PS1 core dylibs + MoltenVK (hardened runtime rejects an unsigned dlopen'd Mach-O;
# same-team signing also satisfies library validation).
for LIB in mednafen_psx_libretro.dylib mednafen_psx_hw_libretro.dylib libMoltenVK.dylib; do
    [ -f "$APP/Contents/Resources/$LIB" ] && \
        codesign -f -o runtime -s "$IDENTITY" "$APP/Contents/Resources/$LIB"
done

codesign --force --entitlements "$ENT" -s "$IDENTITY" "$APP"; rm -f "$ENT"
codesign --verify --strict "$APP" && echo "  signature OK"

echo "▸ Launching…"; open "$APP"
echo "✓ $APP running (CloudKit Development, container $CONTAINER)"
