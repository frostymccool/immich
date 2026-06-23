# Project: frostymccool/immich (custom fork)

Personal fork of immich-app/immich. Custom features stack on
`feature/custom-upload-settings` (the base branch), not on `main`.

---

## Standing rules — apply every session without being asked

### Version bumps
**Always bump `mobile/pubspec.yaml` on every push** so the installed build
is identifiable on-device. Increment both numbers together:
```
3.0.0-custom.N+305N  →  3.0.0-custom.(N+1)+305(N+1)
```

### Branch targets
- New feature branches off `feature/custom-upload-settings`, not `main`.
- PRs target `feature/custom-upload-settings` as base, not `main`.
- Push to the specific `feature/*` branch; never to `main`.

### Engineering discipline — diagnose at the correct layer
Before implementing a workaround, identify the root constraint at the correct
abstraction layer (OS API restriction, framework limitation, protocol constraint,
etc.). If the correct solution requires native code, go native immediately —
do not iterate through higher-level workarounds first.

**Early-warning sign**: reaching a second "I'll try X instead" iteration means
the root-cause analysis was wrong. Stop, re-read the constraint, and ask: is
this fixable at this layer at all? If not, drop down to the layer that owns it.

**Worked example (USB OTG path resolution):**
`file_picker.getDirectoryPath()` returned `"/"` for non-primary volumes on
Android 11+. Root cause: it calls the private `StorageVolume.getPath()` via
Java reflection, which Android blocked at API 30. No Dart-side fix exists.
Correct solution: a native Kotlin plugin using the public
`StorageVolume.getDirectory()` API. Two prior Dart-side iterations were wasted
because the root cause was not identified as an OS-level API restriction first.

### APK builds
`Build Custom APK` (`.github/workflows/build-custom-apk.yml`) triggers
automatically on every push to `feature/**`. The signed release APK artifact
is named `immich-custom-<sha>` with 30-day retention — find it in the
GitHub Actions tab for the run. No manual steps needed.

Note: `Build Mobile` also runs on PRs but skips posting the download comment
for fork repos — use the custom APK workflow artifact instead.

---

## Known pre-existing CI failures (not fixable without fork secrets)

| Check | Reason |
|-------|--------|
| `Run Dart Code Analysis` | DCM requires `DCM_CI_KEY` / `DCM_EMAIL` secrets |
| `validate-release-label` | Requires `PUSH_O_MATIC_APP_KEY` to add `changelog:*` label |

Both failed on PR #1 before any feature work. Ignore them.

---

## Current feature branches

| Branch | PR | Base version | What it adds |
|--------|----|--------------|--------------|
| `feature/custom-upload-settings` | #1 | 3.0.0-custom.3+3051 | See PR #1 below |
| `feature/copyparty-up2k-import` | #2 | 3.0.0-custom.7+3055 | See PR #2 below |

### PR #1 — `feature/custom-upload-settings`
Upload settings overhaul for slow/metered connections:
- `BackupConfig`: added `parallelUploads` (int), `sortSmallestFirst` (bool), `reserveSlotForPhotos` (bool)
- New `SettingsKey` entries: `backupParallelUploads`, `backupSortSmallestFirst`, `backupReserveSlotForPhotos`
- Parallel uploads slider + sort-smallest-first toggle in backup settings UI
- Photo slot reservation (keeps 1 upload slot for photos when uploading videos)
- Upload detail card with bytes transferred + ETA
- Bug fixes: parallel uploads not reaching configured limit, upload detail page bugs

### PR #2 — `feature/copyparty-up2k-import` (stacks on PR #1)
Complete "Import from Memory Card" via the up2k protocol:
- `CopypartyConfig` settings: `hostUrl`, `uploadPath`, `parallelConnections`,
  `autoDeleteAfterVerify`, `writeReceipts`, `triggerExtensions`, `stripPrefixes`
- Password stored in `flutter_secure_storage` under key `copyparty_password`
  (NOT in `SettingsKey` / `AppConfig`)
- DB schema v31: `copyparty_upload_receipts` table + wark index (raw SQL,
  outside Drift entity model — see migration conventions below)
- 5-step import UI: directory picker → scan → options → progress → completion

---

## Mobile project structure

- Flutter 3.44.1 / Dart SDK ≥3.12.0
- State management: Riverpod (`StateNotifierProvider`, `FutureProvider`, `Provider`)
- ORM: Drift for all standard entities; raw SQL for non-Drift tables
- Navigation: auto_route for most pages; `MaterialPageRoute` push for modal flows

### Key config/settings files
| File | Purpose |
|------|---------|
| `mobile/lib/domain/models/settings_key.dart` | `SettingsKey<T>` enum — add new keys here |
| `mobile/lib/domain/models/config/app_config.dart` | `AppConfig` — field + `read()` + `write()` + `copyWith()` for every key |
| `mobile/lib/domain/models/config/*_config.dart` | Per-domain config structs |
| `mobile/lib/infrastructure/repositories/settings.repository.dart` | Singleton; call `ensureInitialized(db)` once per process |

When adding a new settings domain:
1. Create `mobile/lib/domain/models/config/foo_config.dart`
2. Add `final FooConfig foo;` to `AppConfig` with a `const .new()` default
3. Add `read()`, `write()`, `copyWith()` cases for every new key
4. Add enum values to `SettingsKey`

### Database / Drift
| File | Purpose |
|------|---------|
| `mobile/lib/infrastructure/repositories/db.repository.dart` | `Drift` class — schema version, migrations, `beforeOpen` |
| `mobile/lib/infrastructure/repositories/db.repository.steps.dart` | Generated migration steps (versions 1-30) |
| `mobile/test/drift/main/generated/` | Generated schema snapshots (versions 1-30) |

Migration rules:
- Bump `schemaVersion` (currently 31)
- Add raw-SQL migration in `onUpgrade` guarded by version range
- Mirror the same `CREATE TABLE/INDEX IF NOT EXISTS` in `beforeOpen` for fresh installs
- Do NOT regenerate `test/drift/main/generated/` — only covers 1-30 and tests only test to the last generated version
- `Drift` is a singleton accessed via `driftProvider`; test files create it directly with `NativeDatabase.memory()`

### Copyparty feature files
| File | Purpose |
|------|---------|
| `lib/domain/models/config/copyparty_config.dart` | `CopypartyConfig` struct (== uses `_listEquals` for list fields) |
| `lib/domain/models/copyparty/copyparty_models.dart` | `UploadSet`, `UploadFile`, `CopypartyReceipt` models |
| `lib/services/copyparty/copyparty_file_pairer.dart` | Stem normalisation + prefix stripping to group files into upload sets |
| `lib/services/copyparty/copyparty_uploader.service.dart` | Full up2k protocol: hash → handshake → parallel chunk upload → confirm → receipt |
| `lib/infrastructure/repositories/copyparty_receipt.repository.dart` | Raw SQL via `customSelect`/`customInsert`/`customStatement` — NOT a Drift entity |
| `lib/providers/copyparty/copyparty.provider.dart` | `ImportSessionNotifier` state machine + `copypartyPasswordProvider` |
| `lib/pages/copyparty/copyparty_import.page.dart` | 5-step import UI; pushed via `MaterialPageRoute` from `CopypartySettings` |
| `lib/widgets/settings/copyparty_settings/copyparty_settings.dart` | Settings widget; added as `SettingSection.copyparty` in `settings.page.dart` |

Navigation note: `CopypartyImportPage` is NOT registered in `router.dart` (auto_route).
It is pushed directly: `Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CopypartyImportPage()))`.

---

## Test suite

Run with `mise //mobile:test` (= `flutter test`). All tests must pass.

Common gotchas:
- `SettingsRepository` is a static singleton — `ensureInitialized` is idempotent but only the first call's `Drift` instance is used
- Dart context-type inference can make `fold` accumulator nullable when assigned to `int?` param — use explicit type: `fold<int>(0, ...)`
- `flutter test` compiles all lib files; a type error in any lib file fails the compilation for several test files, not just one
