# iOS Beta Build — Handoff Document

## Context

This is a fork of [Immich](https://github.com/immich-app/immich) at `github.com/frostymccool/immich`.

The Android side of this project is complete and working. This document covers what needs to be done to produce a testable iOS build with the same custom features.

---

## Problem being solved

On slow or congested upload connections, the default Immich backup behaviour causes two issues:
1. Large video files occupy all upload slots for minutes, blocking photos entirely
2. There is no way to tune concurrency to the connection quality

The fork adds controls that let you reserve upload slots for photos, sort by file size, and change parallelism mid-backup — making backup on slow connections significantly more reliable.

---

## What's already done (Android, branch `feature/custom-upload-settings`)

All the Flutter/Dart logic is **cross-platform** — it will work on iOS as-is:

| Feature | Where |
|---|---|
| Parallel uploads slider (1–10, default 3) | `mobile/lib/widgets/settings/backup_settings/drift_backup_settings.dart` |
| Upload smallest files first toggle (default on) | same file |
| Reserve 1 slot for photos toggle (default on) | same file |
| Dynamic worker pool — slider change takes effect within ~200ms mid-backup | `mobile/lib/services/foreground_upload.service.dart` |
| File sizes in backup remainder "View Details" list | `mobile/lib/pages/backup/drift_backup_asset_detail.page.dart` |
| Bytes transferred in active upload card | `mobile/lib/pages/backup/drift_upload_detail.page.dart` |
| Settings keys + model wiring | `mobile/lib/domain/models/settings_key.dart`, `backup_config.dart`, `app_config.dart` |

The Android-specific changes (package ID, app label, CI workflow) need iOS equivalents.

---

## What needs to be done for iOS

### 1. Change the iOS Bundle ID and display name

**File:** `mobile/ios/Runner/Info.plist`

Find and change:
```xml
<key>CFBundleIdentifier</key>
<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
```

And in `mobile/ios/Runner.xcodeproj/project.pbxproj`, change `PRODUCT_BUNDLE_IDENTIFIER` from `app.alextran.immich` to `app.immich.custom` in the Release config (keep Debug as-is or give it a `.debug` suffix).

Also in `Info.plist`, change the display name:
```xml
<key>CFBundleDisplayName</key>
<string>Immich Beta</string>
```

This makes it install alongside the official Immich iOS app as "Immich Beta".

### 2. Choose a distribution method

**No paid Apple Developer account is available**, so options are:

#### Option A — Xcode direct install (simplest, requires Mac + iPhone on same network)
- Build on Mac with `flutter build ipa --release` or run directly via Xcode
- Sign with free Apple ID (personal team)
- Install to device via Xcode or Finder
- **Caveat:** 7-day certificate expiry; need to reinstall weekly
- **Best for:** one-off testing while Mac and iPhone are co-located

#### Option B — AltStore (best ongoing experience without paid account)
- Build an unsigned IPA (see CI section below)
- Install once via AltStore on the iPhone (requires AltServer on Mac, same WiFi, one-time)
- AltStore auto-renews the 7-day cert as long as AltServer is running on the Mac
- **Best for:** ongoing testing; Mac stays home, iPhone goes everywhere

#### Option C — SideStore (no Mac needed after initial setup)
- Same as AltStore but uses a WireGuard VPN trick to self-renew without needing AltServer
- Initial setup still requires Xcode or AltStore once
- **Best for:** Mac not always available

#### Option D — Paid Apple Developer account ($99/yr) + TestFlight
- GitHub Actions builds and uploads to TestFlight automatically
- Installs like any app, no expiry, OTA updates
- **Best for:** long-term use; skip if cost is a concern

---

### 3. Build the IPA (on the Mac)

Prerequisites on the Mac:
```bash
# Install Flutter (same version as Android build)
flutter --version  # should be 3.44.1
# If not: https://docs.flutter.dev/get-started/install/macos

cd /path/to/immich/mobile
flutter pub get
dart run easy_localization:generate -S ../i18n
dart run bin/generate_keys.dart
dart run build_runner build --delete-conflicting-outputs

# Build IPA
flutter build ipa --release --no-codesign  # unsigned, for AltStore/SideStore
# OR
flutter build ipa --release  # signed, needs Xcode signing set up
```

The IPA will be at `mobile/build/ios/ipa/immich_mobile.ipa`.

---

### 4. GitHub Actions CI (optional, for automatic IPA builds)

If you want CI to build the IPA automatically on every push:

- Add a new workflow `.github/workflows/build-custom-ipa.yml`
- Use `macos-latest` runner (**note: costs 10× more GitHub Actions minutes than Linux**)
- Build with `flutter build ipa --release --no-codesign`
- Upload as artifact

**Free GitHub tier:** 2,000 Linux minutes/month → equivalent to only ~200 macOS minutes. A single build takes ~15 min, so you'd get ~13 free builds/month. After that it costs money or you wait for the next month.

**Workaround:** Use a self-hosted runner on the Mac itself (free, unlimited). The Claude session with remote Mac access can set this up.

#### Self-hosted runner setup (on the Mac, via Claude remote session)

```bash
# On the Mac:
# 1. Go to github.com/frostymccool/immich/settings/actions/runners
# 2. Click "New self-hosted runner" → macOS → follow the commands
# 3. Run the runner as a service so it starts on boot:
./svc.sh install
./svc.sh start
```

Then update the workflow to use `runs-on: self-hosted` instead of `macos-latest`.

---

### 5. Signing for AltStore (unsigned IPA approach)

AltStore signs the IPA itself using your Apple ID credentials stored on the phone. You just need to provide an **unsigned** IPA. The `--no-codesign` flag above handles this.

When installing via AltStore:
1. Open AltStore on the iPhone
2. Tap the `+` button
3. Navigate to the downloaded `.ipa` file
4. AltStore signs and installs it using your Apple ID

---

## Current repo state

- **Branch:** `feature/custom-upload-settings`
- **Latest version:** `3.0.0-custom.3+3051`
- **Android APK:** Built and signed automatically by GitHub Actions on every push
- **Android signing:** Stable keystore stored as GitHub Actions secrets (`KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_PASSWORD`, `KEY_ALIAS`)
- **PR:** `github.com/frostymccool/immich/pull/1` (open)

---

## Files to check before starting

```
mobile/ios/Runner/Info.plist                          # Bundle ID, display name
mobile/ios/Runner.xcodeproj/project.pbxproj           # PRODUCT_BUNDLE_IDENTIFIER
mobile/android/AndroidManifest.xml                    # Reference for what was done on Android
.github/workflows/build-custom-apk.yml                # Reference CI workflow (Android)
```

---

## Recommended first steps for the new session

1. `git checkout feature/custom-upload-settings && git pull`
2. Check `mobile/ios/Runner/Info.plist` — verify current bundle ID and display name
3. Change bundle ID to `app.immich.custom` and display name to `Immich Beta`
4. Decide on distribution method (see section 2 above) and proceed accordingly
5. If setting up self-hosted runner on Mac, use the Claude session with remote Mac access to register it under `github.com/frostymccool/immich/settings/actions/runners`
