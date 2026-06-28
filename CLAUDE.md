# Project: frostymccool/immich (custom fork)

Personal fork of immich-app/immich. Custom features stack on
`feature/custom-upload-settings` (the base branch), not on `main`.

---

## Standing rules — apply every session without being asked

### Version bumps
**Always bump `mobile/pubspec.yaml` on every push** so the installed build
is identifiable on-device. Increment BOTH numbers by 1 together (the build
code runs 3048 ahead of the custom number):
```
3.0.0-custom.N+<3048+N>  →  3.0.0-custom.(N+1)+<3049+N>
```
Latest pushed: **3.0.0-custom.42+3090** (next push → `43+3091`).

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

### Protocol implementation — read the reference client first
When implementing a third-party protocol, **always read the reference client
source before writing any protocol code**. Never derive the wire format from
general knowledge or assumptions — look at what the canonical client actually
sends.

**When a server says a value "doesn't match spec":** the FIRST action is to find
and read the spec (i.e. the server's validation logic or the reference client).
Do not assume your format is correct and debug why the content is wrong. The
error is equally likely to be a format error as a content error.

**Disambiguation rule:** a "not according to spec" server error has two possible
meanings: (a) wrong format/encoding, or (b) wrong content/value. Always rule out
(a) by reading the reference implementation before debugging (b).

**Worked example (copyparty up2k chunk hash format):**
The handshake returned HTTP 400 "at least one hash is not according to spec".
Two successive wrong diagnoses were made: (1) missing `sz` field, (2) partial
reads producing wrong hash bytes. Both assumed SHA-512 hex was the correct
format. The actual issue: copyparty expects `base64url(sha512(bytes)[:33])`
(44-char URL-safe base64), not `hex(sha512(bytes))` (128-char hex). Reading
`u2c.py` (the reference client, one WebFetch away) would have revealed this
immediately. Three commits and two builds were wasted on wrong diagnoses.

### Debug integrations with instrumentation, not theory
For any client↔server integration failure, the on-device behaviour is the only
source of truth. Do NOT ship speculative fixes or narrate confident root-cause
stories from reading code alone — **build the instrument first, get real data,
then diagnose.** Every breakthrough in the copyparty saga came from a log or an
empirical test; every analysis-only guess was wrong and cost a build + a
round-trip with the user.

Concretely:
- Add verbose, shareable logging (full request/response, computed values) BEFORE
  theorising about a wire-protocol bug. See `CopypartyLogger` + the "Share log"
  buttons — the user runs it, shares one file, and the data decides.
- When a hypothesis is testable on-device, build the test INTO the runtime
  rather than asserting the answer. See the self-test suite
  (`runSelfTest` / `runInstrumentedUpload`) which uploads controlled variations
  (orig / rename / new-content / new-folder) and prints a pass/fail table.
- Never tell the user "it's your server / it works on my reading" without an
  experiment that isolates the layer. The user will (rightly) distrust
  analysis that isn't backed by data — and they have been right to.
- A confident-sounding explanation that you cannot point to a log line for is a
  guess. Label it as one.

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
| `lib/services/copyparty/copyparty_uploader.service.dart` | Full up2k protocol: hash → handshake → parallel chunk upload → confirm. Also server verification (`listFolderSizes`/`verifyPresence`/`verifyHash`) + self-test (`runInstrumentedUpload`) |
| `lib/services/copyparty/copyparty_logger.dart` | `CopypartyLogger` singleton → shareable `copyparty_diag.log` |
| `lib/infrastructure/repositories/copyparty_receipt.repository.dart` | Raw SQL via `customSelect`/`customInsert`/`customStatement` — NOT a Drift entity |
| `lib/providers/copyparty/copyparty.provider.dart` | `ImportSessionNotifier` state machine + `copypartyPasswordProvider` + `copypartyLoggerProvider` + `runSelfTest` |
| `lib/pages/copyparty/copyparty_import.page.dart` | 5-step import UI + "Run upload self-test" action; pushed via `MaterialPageRoute` from `CopypartySettings` |
| `lib/pages/copyparty/copyparty_cleanup.page.dart` | "Pending Cleanup" — multi-state live server verification before delete (never trusts a stored flag) |
| `lib/widgets/settings/copyparty_settings/copyparty_settings.dart` | Settings widget; added as `SettingSection.copyparty` in `settings.page.dart`; Diagnostics section (share/clear log) |

Navigation note: `CopypartyImportPage` is NOT registered in `router.dart` (auto_route).
It is pushed directly: `Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CopypartyImportPage()))`.

### copyparty up2k — verified protocol facts (from logs + `u2c.py`)
- **Chunk SIZE must match the server EXACTLY** (this was THE upload bug — builds
  32–48). copyparty computes each chunk's write offset as
  `index * up2k_chunksize(filesize)`; if the client chunks at a different size,
  the server scatters the bytes across the wrong offsets → corrupt, inflated
  file and a confirm that never completes (no chunk sits where the server
  verifies). Port `copyparty/util.py up2k_chunksize` exactly: start **1 MiB**,
  grow by an accelerating step (`+512 KiB`, step `*1` then `*2`) until
  `nchunks ≤ 256` (or `≤ 4096` once chunk ≥ 32 MiB). NEVER "tune" the chunk
  size for transport reasons — it is a protocol invariant. (Proof: a 6.3 MB
  file sent as 25×256 KiB chunks finalized server-side at
  `24*1MiB + 79753 = 25,245,577 B`.)
- **Chunk id**: `base64url(sha512(chunkBytes)[:33])` → 44-char URL-safe base64, no padding.
- **Handshake**: POST JSON `{name,size,lmod,hash:[cids]}` to the **folder** URL
  (e.g. `/uploads/`). Response: `wark`, `purl` (the URL to POST chunks to — on
  this server it's the bare folder `/uploads/`), `hash` (list of needed chunk
  hash **strings**, NOT indices), `sprs`, `dwrk`.
- **`wark` is content-derived, NOT name-derived.** Proven empirically: a copy of
  a file under a different name returns the *same* wark. So renaming a file does
  NOT give it a new server identity — only changing its bytes does.
- **Chunk upload**: POST chunk bytes to `purl` with headers `X-Up2k-Wark` and
  `X-Up2k-Hash` (single chunk = that chunk's cid), `Content-Type:
  application/octet-stream`. Success = HTTP 200 with body `thank`.
- **Finalize**: re-POST the same handshake to the folder; done when response
  `hash` is empty. (We require `fullyConfirmed` = needs-nothing AND every
  needed hash matched one we computed — a server-needed hash we can't match is
  surfaced loudly, never silently dropped.)
- **Server-side persistence**: copyparty stores in-progress uploads in
  `.hist/up2k.snap` (per volume). This **survives deleting the visible files,
  emptying the folder, and renaming** — only clearing `.hist` (or a true new
  wark, i.e. different bytes) resets it.
- **422** "partial upload exists at a different location" = a stale partial
  (`<name>-<unixtime>-<voltoken>.<ext>`). Do NOT re-POST the handshake to that
  file URL — copyparty answers `400 "some file got your folder name"`. We now
  surface an actionable error instead.

### copyparty up2k — RESOLVED (build 49)
**Uploads work.** Root cause was the chunk-size mismatch documented above: a
256 KiB table introduced in build 36 (for a phantom "nginx body limit") diverged
from copyparty's 1 MiB minimum, so the server wrote our chunks at the wrong
offsets — corrupt files and a never-completing confirm. Fixed by porting
`up2k_chunksize` exactly. The in-app **self-test suite** + **folder snapshots**
(before/after `?ls` listings per attempt) were what finally proved it — the
server-side file sizes exposed the 1 MiB-offset scatter. Lesson reinforced:
the on-device log/snapshot is truth; every analysis-only theory in this saga
(stale state, version mismatch, ordering, lmod) was wrong.

Diagnostic tooling that already exists — use it, don't rebuild it:
- `CopypartyLogger` (singleton) → `<app docs>/copyparty_diag.log`; "Share log"
  buttons in copyparty settings (Diagnostics section) and on the import
  completion screen / self-test results dialog. Log accumulates across runs.
- Cleanup page shows multi-state server verification (name/size/partial/hash),
  not a stored "confirmed" flag — never trust `wark != null` as proof a file is
  safely on the server.

---

## Test suite

Run with `mise //mobile:test` (= `flutter test`). All tests must pass.

Common gotchas:
- `SettingsRepository` is a static singleton — `ensureInitialized` is idempotent but only the first call's `Drift` instance is used
- Dart context-type inference can make `fold` accumulator nullable when assigned to `int?` param — use explicit type: `fold<int>(0, ...)`
- `flutter test` compiles all lib files; a type error in any lib file fails the compilation for several test files, not just one
