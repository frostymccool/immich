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
Latest pushed: **3.0.0-custom.81+3129** (next push → `82+3130`).

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
| `validate-release-label` | Requires `PUSH_O_MATIC_APP_KEY` to add `changelog:*` label |

Ignore that one (needs a fork secret).

**`Run Dart Code Analysis`** is NOT a secrets issue — it runs `dart analyze
--fatal-infos` on the mobile code. `--fatal-infos` means EVEN info-level lints
fail the build, so ANY new violation in our copyparty code turns it red. Build 81
cleaned up 82 such issues (one-line control bodies → braces, `unawaited(...)` on
fire-and-forget futures, `const` constructors, backticked `<…>` in doc comments).
Keep new copyparty code lint-clean: braces on all control bodies, no unawaited
futures, `const` where possible, no bare `<…>`/HTML in `///` comments.

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
Complete "Import from Memory Card" via the up2k protocol, plus a full live
verification + cleanup workflow. Grown well beyond the original 5-step import.

**Config** (`CopypartyConfig`): `hostUrl`, `uploadPath`, `parallelConnections`,
`autoDeleteAfterVerify`, `triggerExtensions`, `allowSelfSignedCert`,
`recreateFolderStructure`, `sortSmallestFirst`, `debugMode`. Password in
`flutter_secure_storage` (key `copyparty_password`, NOT in `SettingsKey`/`AppConfig`).
(`writeReceipts` still exists but is unused — the `.cpreceipt` sidecar was dropped.)

**DB** schema **v32**: `copyparty_upload_receipts` (v31) + `upload_confirmed` /
`immich_asset_id` columns (v32). Raw SQL, outside the Drift entity model.

**Import** — directory picker → scan → options (per-file live name/size/partial
verification + Immich-by-checksum axis, destination CP-only / Both / Immich) →
progress → completion. Groups shown/uploaded in a stable order (smallest-first
optional). Cancel/resume, "add folders" mid-upload, and per-file phase status
(Hashing → Copyparty → Immich) with transfer/total · speed and a done time+avg.

**Pending Cleanup page** — never trusts a stored flag: every file is re-verified
LIVE (name/size/partial via `?ls`, content hash via re-handshake, Immich by
checksum) before any delete. Collapsible groups, rolled-up per-group status,
select-verified, per-file "Upload now" recovery + "Remove from list".

**Entry points** — main app-bar memory-card indicator (spins while uploading) +
the copyparty settings pages (main = full config; backup-embedded = simplified,
server section hidden, URL in the title).

**Diagnostics** gated behind `debugMode` (off by default): self-test / share-log
links hidden in normal use; a "Download log" button stays on the main settings.

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
- Bump `schemaVersion` (currently 32)
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

## Copyparty cleanup-phase plan (✅ DONE — shipped builds 51–55)

All 9 issues below are **implemented and shipped**. Kept here as the design
record (decisions + rationale). The verification/cleanup model described here is
now the live behaviour. Many further feedback rounds built on top (see below).

Uploads work (build 49). These 9 follow-up issues were the agreed next work,
captured from on-device testing. **Locked design decisions (asked + answered):**
- **Picker hashing [A]**: name/size verified LIVE on scan; the content HASH is
  checked only at upload time (the handshake) or via a per-file "Verify hash"
  button. Show "hash not checked" honestly until then. (Fast scans.)
- **Immich presence [B]**: determined by **file CHECKSUM** via Immich's
  bulk-upload-check endpoint, NOT just the stored asset id — user wants
  certainty before any deletion.
- **Delete UX [A]**: smart — one-tap "Delete all N" when every selected file is
  hash-verified on copyparty AND Immich-good; drop to a per-file pick-list only
  when something is unverified (unsafe rows start unticked).
- **Picker default selection [A]**: tick only files whose name+size do NOT match
  the server; already-present ones start unticked.

**Unifying design**: ONE verification model — extend `ServerFileVerification`
(name / size / partial / hash) with an Immich axis — used on BOTH the import
picker and the cleanup page. NEVER trust a stored receipt as proof; always
verify live. (Proposal mockups were rendered in-session via headless Chromium.)

### Phase 1 — upload correctness & honesty
1. **(Issue 2) Duplicate `-<time>-<token>` files.** `uploadFile` must NOT send
   the confirm handshake when the INITIAL handshake already returns
   `fullyConfirmed` (content deduped / already complete). The redundant confirm
   re-registers the now-existing name → copyparty serialises a duplicate. Return
   immediately when init is fullyConfirmed.
2. **(Issue 1) False "Completed with errors".** Completion screen must count
   only ATTEMPTED files (`status != pending`). Skipped/unselected files must not
   count toward cp/immich needed totals or the error state.
3. **(Issue 6) Upload rate (MiB/s) missing.** Fix the speed calc / progress
   wiring (likely too few ticks now chunks are 1 MiB; ensure onUploadProgress
   drives a visible live rate).

### Phase 2 — unified live verification (picker + cleanup)
4. **(Issue 3) Picker trusts receipts.** Verify LIVE (copyparty `?ls` name+size)
   instead of the receipt DB; drop the blanket "Confirmed: copyparty"; show
   "hash not checked" honestly.
5. **(Issue 4) Hash drives skip/upload.** At upload, if the handshake is
   `fullyConfirmed` (hash already on server) skip the byte upload and show
   "already on server — hash verified"; else upload + confirm. Make hash state
   visible per file.
6. **(Issue 9) Partial/name accuracy + wording.** Treat a 0-byte file + a
   `.PARTIAL` sibling as NOT present / incomplete. Relabel affirmatively:
   "⚠ partial exists" (red) when one exists; "no partial ✓" only when none.
   Re-verify on open / refresh — no stale snapshots.
7. **(Issue 7) Immich axis on cleanup (and picker).** Per-file Immich presence
   by checksum (decision B); "CP-only" files show Immich n/a.

### Phase 3 — delete & recovery UX
8. **(Issue 5) Status-driven delete.** All-verified → one-tap "Delete all N"
   with an explicit all-clear; mixed → per-file pick-list with unsafe rows
   unticked. Safe = copyparty hash-verified AND (Immich present OR not
   Immich-bound). Applies to both the completion screen and Pending Cleanup.
9. **(Issue 8) Recover from failed Verify.** On Pending Cleanup, a failed Verify
   offers an "Upload now" action to re-upload that file (cleanup doubles as
   recovery).

Immich checksum lookup: use the generated openapi `AssetsApi` bulk-upload-check
(`/assets/bulk-upload-check`; checksum = base64 SHA-1) — confirm the exact
generated method name during implementation.

---

## Copyparty feedback rounds (✅ DONE — builds 56–79)

Everything below is shipped. Each landed build was compile-reviewed (no local
Dart toolchain — the CI APK build + review agents are the gate) and most
data-safety-touching batches went through a 3-persona review.

- **Delete safety**: completion-screen delete re-verifies with a fresh hash
  against the file's ACTUAL (FB9-mirrored) folder; deletion is BLOCKED when the
  server is unreachable (never "delete anyway" offline). `verifyHash` clears the
  stale hash on any non-success so a failed re-verify drops out of "safe".
- **FB9 folder mirror** is a persistent setting (`recreateFolderStructure`) — the
  picked folder's own name becomes the top-level server subfolder; URLs are
  percent-encoded (`mirroredUploadPath` is a public top-level fn).
- **Picker**: verifies each file's mirrored target folder (a 404 = folder not
  created yet = empty, NOT "offline"); single-file groups render flat; group
  headers roll up name/size/hash/Immich with per-axis known-count denominators;
  Immich-present files auto-switch to CP-only; header shows a CP/Immich breakdown.
- **Progress**: dynamic queue loop (add folders mid-run via `addFolders`, honours
  smallest-first, shown in upload order); phase chip Hashing→Copyparty→Immich;
  compact "transferred / total · speed"; done shows "total · elapsed · avg"
  (speed excludes hashing). Cancel with resume-safe pending state; "Add folders".
- **Auto-delete after verify** runs after BOTH backends, gated by `safeToDelete`
  (requires the Immich asset id for Immich-native files).
- **Cleanup**: `pendingCleanupProvider` filters to files that still exist on
  device (DISPLAY ONLY — never `markSourceDeleted` from a passive read, since an
  unmounted card makes `exists()` false transiently). Collapsible groups +
  expand/collapse all, "Select verified", per-file "Remove from list".
- **Settings**: `debugMode` (default off) hides self-test/log links everywhere,
  keeps a "Download log" button on the main page. `sortSmallestFirst` (by group
  total size). The backup-entry copyparty page hides the server section (lives in
  main settings) and shows the full URL in its title.
- **App bar**: memory-card indicator left of the backup indicator; spins while an
  import upload is active.

---

## Test suite

Run with `mise //mobile:test` (= `flutter test`). All tests must pass.

Common gotchas:
- `SettingsRepository` is a static singleton — `ensureInitialized` is idempotent but only the first call's `Drift` instance is used
- Dart context-type inference can make `fold` accumulator nullable when assigned to `int?` param — use explicit type: `fold<int>(0, ...)`
- `flutter test` compiles all lib files; a type error in any lib file fails the compilation for several test files, not just one
