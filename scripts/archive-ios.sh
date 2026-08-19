#!/usr/bin/env bash
# Archive the iOS app (Release) and export a signed .ipa for App Store / TestFlight.
#
# PREREQUISITES (one-time, must be done by the account owner — can't be automated headless):
#   1. Apple Developer Program membership (have it: team JLR4F273N8).
#   2. In App Store Connect, create the app record for bundle id `com.comalada.gbaemulator`.
#   3. Provision the CloudKit container `iCloud.com.comalada.gbaemulator` (Xcode → target →
#      Signing & Capabilities → iCloud, or the CloudKit dashboard) — required because the app has
#      the iCloud entitlement. This exact id must match EmulatorApp.entitlements and the
#      `cloudContainer` constant in both apps' ContinuityService; the SAME container must be enabled
#      for the macOS app too, so the two devices share one CloudKit database (that's what makes
#      cross-device Continue + "Send to My Devices" work).
#   4. Register at least one device (plug an iPhone into Xcode once) OR ensure an App Store
#      distribution certificate + profile exists. Automatic signing creates these with
#      -allowProvisioningUpdates once the above are in place.
#
# Then run this. The .ipa lands in apps/ios/build/export/. Upload via Xcode Organizer, or:
#   xcrun altool --upload-app -f build/export/*.ipa -t ios --apiKey <KEY> --apiIssuer <ISSUER>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/apps/ios"

echo "== Archiving (Release) =="
xcodebuild -project EmulatoriOS.xcodeproj -scheme EmulatorApp \
    -sdk iphoneos -destination 'generic/platform=iOS' -configuration Release \
    -archivePath build/EmulatorApp.xcarchive \
    -allowProvisioningUpdates archive

echo "== Exporting .ipa (App Store) =="
xcodebuild -exportArchive \
    -archivePath build/EmulatorApp.xcarchive \
    -exportOptionsPlist ExportOptions.plist \
    -exportPath build/export \
    -allowProvisioningUpdates

echo
echo "Done. IPA(s):"
ls -la build/export/*.ipa 2>/dev/null || echo "  (export failed — see errors above)"
