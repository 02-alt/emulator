# Shipping checklist — cross-device Send / Continue (CloudKit)

**End users do nothing.** Everything below is one-time developer setup that gets baked into the
released app. A user just installs Encore, is already signed into iCloud, and Send/Continue works —
each user's data lives in *their own* private iCloud database (never a shared server).

We built and tested against the **Development** CloudKit environment. Real (App Store / notarized)
builds use the **Production** environment. Two things must be true for production:

---

## 1. Deploy the CloudKit schema to Production (once)

The record types + indexes exist in **Development** but not yet in **Production**.

- CloudKit Console (icloud.developer.apple.com) → container **`iCloud.com.buildtoberemembered.encore`**
- **Deploy Schema Changes…** → review → **Deploy to Production**.
- This carries over the record types `ContinuitySnapshot` + `ContinuityROM` and the **`recordName`
  Queryable** indexes. Re-run after any future schema change (a new field, etc.).

## 2. iOS — App Store build

- The entitlement no longer pins an environment (`apps/ios/EmulatorApp.entitlements`), so:
  - development / debug builds → CloudKit **Development** (what we test on),
  - App Store / TestFlight archives → CloudKit **Production** — automatically.
- Archive with `scripts/archive-ios.sh` (or Xcode → Product → Archive) and upload. Nothing else to flip.

## 3. macOS — notarized Developer ID build

Unlike iOS, the Mac app needs a **provisioning profile** embedded to carry the iCloud entitlement.

1. developer.apple.com → **Profiles** → **+** → **Developer ID** (distribution, not the Development one
   we use for local testing) → App ID **`com.buildtoberemembered.encore`** → your **Developer ID
   Application** cert → Generate → Download.
2. Run the release with that profile:
   ```sh
   PROFILE=~/Downloads/Encore_DeveloperID.provisionprofile ./scripts/release.sh 1.0.0
   ```
   `release.sh` embeds the profile, signs with the iCloud entitlement (Production), hardened runtime,
   then notarizes + staples. Without `PROFILE` it builds as before, but **without** iCloud.
3. First-time only: store the notarization credentials (see the header of `release.sh`).

---

Local dev testing (Development env, no notarization) stays on `scripts/dev-macos.sh`.
The iOS app id is `com.comalada.gbaemulator`; the macOS app id is `com.buildtoberemembered.encore`;
both are associated with the same container so the two devices share one private database.
