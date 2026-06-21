# Project: frostymccool/immich (custom fork)

This is a personal fork of immich-app/immich. Custom features live on
`feature/*` branches that stack on top of `feature/custom-upload-settings`
(the base branch for all personal additions).

## Standing rules — apply every session, no need to ask

### Version bumps
**Always bump `mobile/pubspec.yaml` on every push** so the installed build
is identifiable. Increment the pre-release number and build number together:
```
3.0.0-custom.N+305N  →  3.0.0-custom.(N+1)+305(N+1)
```

### Branch targets
- All new feature work branches off `feature/custom-upload-settings`, not `main`.
- Push to the specific `feature/*` branch, never to `main`.

## APK builds

The `Build Custom APK` workflow (`.github/workflows/build-custom-apk.yml`)
triggers automatically on every push to any `feature/**` branch. It produces
a signed release APK artifact named `immich-custom-<sha>` with 30-day
retention, downloadable from the Actions tab for the run.

The upstream `Build Mobile` workflow also runs on PRs but skips posting the
download comment for fork repos — use the custom APK workflow artifact instead.

## Known pre-existing CI failures (not fixable without fork secrets)

| Check | Reason |
|-------|--------|
| `Run Dart Code Analysis` | DCM requires `DCM_CI_KEY` / `DCM_EMAIL` secrets |
| `validate-release-label` | Requires `PUSH_O_MATIC_APP_KEY` to add `changelog:*` label |

Both were failing on PR #1 and are unrelated to any feature work. Ignore them.

## Mobile project structure

- Flutter 3.44.1 / Dart SDK ≥3.12.0
- Riverpod state management (`StateNotifierProvider`, `FutureProvider`)
- Drift ORM for SQLite; raw SQL for non-Drift tables
- Settings live in `AppConfig` / `SettingsKey` enum in
  `mobile/lib/domain/models/`
- DB schema version lives in `mobile/lib/infrastructure/repositories/db.repository.dart`
  — bump `schemaVersion` and add migration for any new tables
- Passwords/secrets use `flutter_secure_storage`, not `SettingsKey`
- Run `mise //mobile:test` (`flutter test`) for the full test suite

## Drift schema migrations

When adding a new DB table:
1. Bump `schemaVersion` in `db.repository.dart`
2. Add raw-SQL migration in the `onUpgrade` block guarded by version range
3. Add `CREATE TABLE IF NOT EXISTS` + index to `beforeOpen` for fresh installs
4. Do NOT regenerate `test/drift/main/generated/` — only covers versions 1-30
   and the migration tests only test up to the last generated version

## Current feature branches

| Branch | PR | Description |
|--------|----|-------------|
| `feature/custom-upload-settings` | #1 | Parallel upload settings, upload detail page, ETA |
| `feature/copyparty-up2k-import` | #2 | Copyparty up2k import from memory card |
