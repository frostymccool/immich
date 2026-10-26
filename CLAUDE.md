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
3.3.3-custom.N+<3048+N>  →  3.3.3-custom.(N+1)+<3049+N>
```
Latest pushed to the build branch: **3.3.5-custom.227+3275** (next push → `228+3276`). 227 = bridge only (`[skip ci]`): the Status tab shows WHICH Immich account the API key belongs to (`ImmichClient.whoami()` → `GET /api/users/me`; shown only behind the token, in `/api/config` → `readonly.immich_user`, NEVER in the open `/status`) and links to the folder albums used (`readonly.albums`, `{immich_url}/albums/{id}`). Reason: the user's bridge log showed 12 successful `album 'X' <- file` adds, the key valid for albums, and no "created album" line (album already existed) — yet the user could not see the album in Immich. Leading hypothesis (UNCONFIRMED): the API key belongs to a different Immich user than the one the user browses as (assets+albums are owned by the key's user). Confirm with the user by opening `/photos/<asset id from the log>` while logged in. 226 = 226 = bridge only (`[skip ci]`): **Pause / Resume imports** — `Config.paused` (editable+persisted setting, so a restart stays paused; `POST /api/pause {paused:bool}`; `/status` reports `paused`); workers wait in `_wait_while_paused` (a file already being imported finishes; a file a worker took from the queue is held, counted in `queue_size`, and not re-queued); hook/sweep keep queuing; header button + amber banner + pill on the page; the phone app tile does NOT show paused yet (it ignores unknown `/status` fields). 225 = 225 = bridge/installer only (`[skip ci]`): folder albums are now DIAGNOSABLE — `ImmichClient.album_permission_status()` reads the key's permissions via `GET /api/api-keys/me` (needs no permission; Immich spec: albums need `album.read`+`album.create`+`albumAsset.create`, or `all`), the installer prints a NOTE if the key lacks them, the bridge logs a WARNING at start and the Status tab shows a red banner; `add_to_album` now checks Immich's per-asset result list (200 can still mean `no_permission`; `duplicate` = already in album = success) and counts successes/failures/last error (`/status` → `albums`); a **back-fill** (`worker.start_backfill`, `StateStore.done_assets`, `POST /api/albums/backfill`, button on Folders & settings) adds files imported before the feature/while the key lacked permission. Root cause hypothesis for "no albums": key without album permissions (an API-spec-verified failure that used to be only a log WARNING) and/or only already-imported files looked at — unconfirmed until the user's log/banner is seen. 224 = 224 = installer bug fix (bridge/installer only, `[skip ci]`): on a RE-run the copyparty container also has the hook script mounted at `/hooks/…` and Docker lists mounts alphabetically, so "first mount that isn't /cfg" picked the hook file as the data folder (the prompt said "inside /hooks/immich_bridge_hook.py"). Fixed: mounts are read with their Type, `/cfg` + `/hooks` + file mounts are skipped, a re-run prefers the previous `BROWSE_ROOTS`; the first-install question now lists the real folders newest-first (type a number). Regression tests `copyparty-immich-bridge/tests/test_install_sh.py` run install.sh against fake docker/git/curl whose `inspect` mimics Docker's mount order WITH the hook mount (the old installer fails 5 of them) — **any installer change must keep these green; the old stub didn't mimic real Docker and hid this bug.** 223 = bridge-only (committed `[skip ci]`, no APK rebuild): **folder-named albums** — every imported (or already-in-Immich) file is added to an Immich album named after the folder it sits directly in, created on demand (`ALBUM_FROM_FOLDER`, default ON, editable on the settings page; `scanner.folder_album_name`, `worker._albums_for`; hidden folders skipped; the optional fixed `IMMICH_ALBUM_NAME` still applies in addition; `ImmichClient` caches album ids per name and re-creates an album the user deleted in Immich; album failures are logged, never fail the import; files imported BEFORE this feature are added by the back-fill button). 222 = docs/installer-only (committed with `[skip ci]` so it did not rebuild the APK): `install.sh` no longer hard-codes the owner's folder names — it asks once for the app upload folder (or `APP_FOLDER=`; `.` = whole data folder), remembers it by reading its own previous override file, `BASE_FOLDER` defaults to the folder containing it; screenshots/docs/tests use generic names (Trips/Summer2026). Build 221 = release of the batch 215–220: "Verify then delete" on Pending Cleanup (`_verifyThenDeleteSelected`), stuck "Queued…" snackbar fix (`copyparty_snackbar.dart`: Flutter keeps SnackBars that have an action forever unless `persist:false`; the action uses a pre-captured NavigatorState), Insta360 grouping fix (`CopypartyFilePairer.normalise` drops the 2-digit type/lens field in `PREFIX_YYYYMMDD_HHMMSS_LL_NNN`, so LRV_…_01_004.lrv pairs with VID_…_00_004.insv and VID_…_10_004.insv; `test/services/copyparty_file_pairer_test.dart`), stray `.PARTIAL` handling (complete file + leftover partial = amber "duplicate partial", not a red failure: Verify offered instead of "Upload now"; after a hash-verified delete the leftover is removed from copyparty via the ONLY normal-flow server delete, `CopypartyUploaderService.removeStrayPartials` — re-lists first, needs the complete non-empty file, exact `<name>.PARTIAL`/`.<name>.PARTIAL` only, never the suffixed form; needs a delete-capable copyparty login, failures are reported not thrown; `ServerFileVerification.strayPartial/looksLikeStrayPartial`; `test/services/copyparty_stray_partial_test.dart`; NOT yet confirmed against a real server — if Verify on such a row fails, read the diag log: a 422 "partial exists" handshake would block verification), and import-page labels for staging to the phone cache (Caching bubble, "cached 5%", Cached). Earlier: 214 = CI gives Gradle -Xmx6144M via ~/.gradle/gradle.properties after repeat "Java heap space" failures (builds 204, 209); 213 = audit is a first step in the APK build job (no reusable-workflow `./` call, zizmor), shellcheck-clean; 211 = fork audit wired into every pipeline, 212 = audit checks the real PR head commit instead of GitHub's synthetic merge; 209 = the "config upgrade" below; synced to upstream v3.3.5. **Pushes to `feature/**` DO trigger the APK build** (run listings can lag — never also dispatch by hand); the `claude/*` branch is the no-build parking branch for unreleased work. Jumped 132→200 on purpose to mark the copyparty-immich-bridge addition.

Note: another Claude Code session may also be working on this fork in parallel on branch
`claude/auto-immich-copyparty-upload-eq80lh` (not `feature/copyparty-up2k-import` itself — it
rebases its own branch on top of this one). It bumps `mobile/pubspec.yaml`'s version independently
too, so the custom build number here can skip ahead non-sequentially if that session pushed since
this file was last read — always check the actual latest pushed commit's `pubspec.yaml`, not just
this note, before picking the next number.

The `3.3.3` base tracks the upstream immich-app/immich release this fork is
synced to — bump it (and re-derive the offset if upstream's own build number
shifted) the next time upstream gets pulled in, not on every push.

Upstream's release-branch process does NOT keep `main` as a clean linear
history across releases — e.g. v3.2.0 and v3.3.3 weren't a fast-forward of
each other (40 commits unique to the old v3.2.0 path, 288 new on v3.3.3's).
When the next sync hits this, `git merge --ff-only <tag>` on `main` will fail;
don't try a real 3-way merge either (it surfaces dozens of synthetic
conflicts in files like pnpm-lock.yaml/package.json/server-* with no real
fork content to resolve, since `main` has zero fork-specific commits). Just
confirm with the user, then `git reset --hard <tag>` + force-push `main` to
exactly match the new tag. When merging that into
`feature/custom-upload-settings` afterward, most conflicts will similarly be
upstream-only churn — diff each conflicted file against the PREVIOUS sync
point (not some ancient merge-base) to tell which ones the fork actually
touched; take "theirs" wholesale for the rest.

### Local Dart toolchain now available for formatting
A standalone Dart SDK can be fetched directly (bypasses the "no local Dart
toolchain" limitation for `dart format`, though not for `flutter analyze`/build):
```
curl -sS -o /tmp/dartsdk.zip https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-linux-x64-release.zip
unzip -q /tmp/dartsdk.zip -d /tmp/dart-sdk
/tmp/dart-sdk/dart-sdk/bin/dart format --line-length 120 <files>
```
Only pass specific files or use the same exclusions CI does
(`-not \( -name '*.g.dart' -o -name '*.drift.dart' -o -name '*.gr.dart' \)`) —
running it over the whole `lib/` tree unfiltered reformats generated files
that CI's format step deliberately skips, producing an unrelated diff.

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

### HTML explainers/mockups must show concrete examples
Whenever an HTML page (flow diagram, mockup, review page) describes something the user will
"see", include a realistic example of it (fabricated data is fine, say so on the page): real-looking
terminal output, log lines, JSON, file names, the app tile as rendered. Prose alone is ambiguous
to the user. See `copyparty-immich-bridge/docs/bridge-flow.html` (the `EX` table).

### Fork audit — mandatory, automatic, and fail-closed
`scripts/fork-audit.sh` checks for tracked secret files (.env/keystores/keys/certs/DBs/logs/APKs), high-confidence
secrets, personal data in FORK-OWNED paths (private IPs, personal e-mails, real home dirs, real-looking tokens,
non-generic prompts), `.gitignore` coverage, the tip commit's author e-mail, and (`--apk <file>`) secrets packaged
inside a built APK. It runs: locally via `.githooks/pre-push` (**enable once per clone: `git config core.hooksPath
.githooks`** — do this at the start of every new session/container), in `fork-audit.yml` on every push/PR/dispatch,
as a required `audit` job before `build-custom-apk.yml` builds anything (plus an APK-contents check before the artifact
is uploaded), and in `bridge-tests.yml`. Run it by hand before pushing if the hook isn't enabled. A failing audit
blocks the build — fix the finding, never weaken the script; if upstream legitimately adds a sensitive-looking file
(placeholder/test key), review it and add it to `ALLOW_FILES` with a reason. The fork-owned path list (`OWN`) in the
script must be extended when new fork-only directories/files are added. Upstream-inherited release workflows
(docker.yml, fdroid.yml, prepare-release.yml …) are not modified (merge churn) but cannot run meaningfully on this
fork; the standalone audit still runs on every push regardless.

### Keep personal details out of the repo (public fork)
Never commit real LAN IPs, hostnames, user names, NAS paths, trip/folder/album names (the owner's real ones — also in placeholders, screenshots and test data; grep case-insensitively and with spaces), tokens, API keys, `.env` files,
keystores or logs. Use generic examples (`192.168.1.50`, `user@docker-vm`, `/mnt/uploads`, an obviously
fake token). `.gitignore` covers `immich-bridge*.env`, `docker-compose.override.yml`, `key.properties`,
`*.jks/*.keystore/*.p12/*.pem`, bridge `state.db`/`settings.json`/logs. Audit done at build 210: no secrets in
the fork's own commits; earlier commits (pre-210) still contain the owner's private LAN IP/hostnames in examples —
history was deliberately NOT rewritten (non-routable, and a rewrite of a 129-commit public fork is destructive).

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

**DB** schema **v36**: `copyparty_upload_receipts` (v35) + `upload_confirmed` /
`immich_asset_id` columns (v36). Raw SQL, outside the Drift entity model.

**Import** — directory picker → scan → options (per-file live name/size/partial
verification + Immich-by-checksum axis, destination CP-only / Both / Immich) →
progress → completion. Groups shown/uploaded in a stable order (smallest-first
optional). Cancel/resume, "add folders" mid-upload, and per-file phase status
(Hashing → Copyparty → Immich) with transfer/total · speed and a done time+avg.

**Pending Cleanup page** — never trusts a stored flag: every file is re-verified
LIVE (name/size/partial via `?ls`, content hash via re-handshake, Immich by
checksum) before any delete. Collapsible groups, rolled-up per-group status,
select-verified, per-file "Upload now" recovery + "Remove from list".

**Verify then delete** (Pending Cleanup bottom bar, left of "Delete N files"): active when any file is ticked;
after one confirmation it verifies each ticked file in turn (`_verifyFile`, the same live re-hash + Immich check) and
deletes THAT file immediately if `safeToDeleteAt` passes (never batched at the end); failed files are left untouched
and ticked; the button turns into a "tap to stop" control while running. No widget test exists for this page yet (the shared snackbar helper and stray-partial logic do have tests).

**Entry points** — main app-bar memory-card indicator (spins while uploading) +
the copyparty settings pages (main = full config; backup-embedded = simplified,
server section hidden, URL in the title).

**Diagnostics** gated behind `debugMode` (off by default): self-test / share-log
links hidden in normal use; a "Download log" button stays on the main settings.

**"All files access" permission prompt** (`copyparty_import.page.dart`,
`_DirectoryPickerStepState`): when MANAGE_EXTERNAL_STORAGE isn't granted, the "Open Settings"
button calls `Permission.manageExternalStorage.request()` (opens the dedicated "All files access"
screen directly) and auto-starts the scan if granted — NOT `openAppSettings()`, which only opens
the generic app-info page where that permission isn't listed. Fixed by the parallel
`claude/auto-immich-copyparty-upload-eq80lh` session and merged in during the v3.3.4 sync.

---

### `copyparty-immich-bridge/` — server-side auto-import (added build 200)
Standalone Python service (not part of the mobile app) that watches the copyparty upload
volume and imports completed files into Immich via its API, from ANY uploader — complementary
to the mobile "Import from Memory Card" flow. Two delivery paths: copyparty's `xau` event hook
(`hook/immich_bridge_hook.py`, instant, forked so it never blocks uploads) POSTs to the bridge's
`/hook`, plus a periodic sweep as the reliability backstop. Dedup via Immich's
`bulk-upload-check` (SHA-1); SQLite state DB tracks per-file (size, mtime) so nothing is
re-imported; default `POST_IMPORT_ACTION=keep` never touches source files. Config is all env
vars (see its README). `PRIORITY_DIRS` (inside `WATCH_DIRS`) are imported first via a priority
queue — set it to the folder the phone app uploads into; the rest of the copyparty base is still
imported afterwards, and `/status` reports both so the app tile can show them. Known gap: `/hook` has no auth (it now ignores any path outside `WATCH_DIRS`) — keep port 8099 on the internal Docker
network only. **Install: `copyparty-immich-bridge/install.sh`** (documented in its `INSTALL.md`) is a one-line `curl | bash` that auto-detects the copyparty container/data mount, validates the Immich API key, clones the sparse bridge source, writes a separate `docker-compose.override.yml` (never edits the user's compose; delete it to undo), builds/starts, falls back to sweep-only if the hook stops copyparty starting, and supports `WIDE=1`, `HOOK=0`, `--uninstall`. It was tested only against stubbed docker/git/curl (no Docker daemon in the sandbox) — if the VM run misbehaves, check that first. Tests: `cd copyparty-immich-bridge && python -m pytest tests/` (~90 tests; `pip install pytest requests` first); CI is
`.github/workflows/bridge-tests.yml`, path-scoped to that directory. Originally built by a
parallel Claude session (branch `claude/auto-immich-copyparty-upload-eq80lh`, now retired).

**Config upgrade (build 209) — web page on the bridge itself.** `GET /` serves `bridge/web/index.html`
(single file, vanilla JS): Status, Folders & settings (multi-folder picker, ★ priority, scan interval,
file-age guard, retry budget, post-import action, album, file types, log level), Logs (live tail,
filter, download), Scan now. Backend is `/api/config` (GET/PUT), `/api/config/reset`, `/api/fs`,
`/api/logs[/download]`, `/api/scan` in `server.py`; `bridge/settings.py` validates all-or-nothing, applies to the
live `Config` (no restart) and persists only differences from env to `SETTINGS_FILE` (`/data/settings.json`,
saved values WIN over compose/installer values until "Reset"); `bridge/browse.py` lists only dirs inside
`BROWSE_ROOTS` (symlink-safe; the container can only see what's mounted — installer mounts the whole copyparty
data root, `WRITABLE=1` for rw); `bridge/logbuffer.py` is the 2000-line ring buffer. **Auth:** `BRIDGE_TOKEN`
(installer generates, stores in `immich-bridge.env`, reuses on re-run, prints `http://ip:8099/#token=…`); with no
token `/api/*` answers 403 (settings can never change anonymously); when set it is also required on `/hook`
(hook script sends `IMMICH_BRIDGE_TOKEN` from `immich-bridge-hook.env`, a file holding ONLY the token so the
Immich API key never reaches copyparty). `/healthz` + `/status` stay open (the phone app reads them). Port, Immich
URL/key, workers and mounts stay installer-only by design. App side: the running tile gained an "Open bridge
settings page" row (`BridgeStatus.baseUrl`, `launchUrl`; still only on the settings page, hard rule intact).
Screens: `copyparty-immich-bridge/docs/ui-*.png`, shown in tab 4 of the flow page.

Animated walkthrough of install / import / status / config-upgrade flows: `copyparty-immich-bridge/docs/bridge-flow.html` (self-contained, open in any browser; update it if the pipeline changes).

**App-side status display (build 202):** Settings → copyparty → "Import Bridge (optional)" has a
`bridgeUrl` setting (`SettingsKey.copypartyBridgeUrl`, blank = feature off) and a live status tile.
`ImmichBridgeStatusService` (`lib/services/copyparty/immich_bridge_status.service.dart`) reads the
bridge's `/healthz` + `/status` and maps EVERY failure (blank/bad URL, down, timeout, garbage
JSON) to a `BridgeStatus` — it never throws. `immichBridgeStatusProvider` is autoDispose, so it
only runs (4s timeouts, 15s refresh) while the settings page is open; nothing polls at app start
or in the background. **Hard rule: no other app function may read `bridgeUrl` or depend on the
bridge** — the APK must work identically with the bridge absent. Tests:
`test/services/immich_bridge_status_service_test.dart`.

---

## Mobile project structure

- Flutter 3.47.2 / Dart SDK ≥3.12.0
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
As of v3.2.0, moved from `lib/infrastructure/repositories/` to `lib/data/db/`
(upstream restructuring); the class name (`Drift`) and `driftProvider` are unchanged.

| File | Purpose |
|------|---------|
| `mobile/lib/data/db/main/database.dart` | `Drift` class — schema version, migrations, `beforeOpen` |
| `mobile/lib/data/db/main/database.steps.dart` | Generated (gitignored) via `dart run drift_dev make-migrations` — provides `migrationSteps(...)` |
| `mobile/drift_schemas/main/*.json` | Schema snapshots, one per drift-tracked version (real content up to v34 — v36/v37 are auto-generated placeholders, see below) |
| `mobile/test/drift/main/generated/` | Generated (gitignored) via `dart run drift_dev schema generate ...` |

Migration rules:
- Bump `schemaVersion` (currently 37 — see note below on why it's ahead of the last drift snapshot)
- Add raw-SQL migration in `onUpgrade` guarded by version range
- Mirror the same `CREATE TABLE/INDEX IF NOT EXISTS` in `beforeOpen` for fresh installs
- `Drift` is a singleton accessed via `driftProvider`; test files create it directly with `NativeDatabase.memory()`
- Upstream's `onUpgrade` re-reads the actual `PRAGMA user_version` as `current` inside the
  transaction (race-safety fix, added in the v3.3.3 sync) rather than trusting the `from`
  parameter — the copyparty raw-SQL guards below use `current` too, for the same reason.

**copyparty's schema versions are raw SQL, not drift-tracked.** `copyparty_upload_receipts`
isn't a Drift entity, so its table-creation and column-adding migrations are hand-written
`customStatement(...)` calls in `onUpgrade`, gated by `if (current < N && to >= N)` — NOT part
of the generated `migrationSteps(...)` helper. This means `schemaVersion` can be (and is) ahead
of the highest real drift-schema version (currently v34): `dart run drift_dev make-migrations`
still requires a `from34To36` (or whatever the gap is) parameter on `migrationSteps(...)` once
it notices the version jump and auto-creates a matching (structurally-identical) placeholder
schema snapshot — provide it as a no-op, since the actual work happens in the raw-SQL block
below it. **This raw-SQL ceiling gets renumbered on every sync that adds real upstream schema
versions** — it's been v31→v32→v33 (after the v3.1.0 sync), then v34→v35→v36 (after v3.3.3,
once upstream's own schema grew from v31 to v34). Expect to renumber it again next time.
**Always guard column-adding ALTER TABLEs with a `pragma_table_info` check, not just a version
number** — a prior renumbering (during the v3.1.0 sync) taught this the hard way: devices
already on an older numbering scheme can have stored versions that don't mean what the current
code assumes, causing a `duplicate column name` crash on upgrade (fixed in build 121).

**Build 129 regression (v3.3.3 sync), fixed in build 130 — `schemaVersion` is now 37.** The
`pragma_table_info` lesson above was only applied to the copyparty-specific column guards, not
to the *generated* `migrationSteps(...)` call itself, and that gap bit for real: devices still
on the OLD pre-sync raw-SQL numbering (stored `user_version` 32 or 33, meaning real upstream v31
content + copyparty's old table/columns) collided with upstream's own schema growing into that
same 32/33 range in the v3.3.3 release (real v32 adds `local_asset_entity.previous_checksum`,
real v33 drops an `asset_face` foreign key). The code trusted the stored version number, assumed
those two real steps were already applied, and silently skipped them — every local-asset hash
and sync call then crashed with `no such column: local_asset_entity.previous_checksum`, which
meant **zero files were ever selected for backup** (confirmed via the in-app log, not guessed —
see the engineering-discipline section above). Fix: `database.dart`'s `onUpgrade` now computes a
separate `generatedStepsCurrent` for the generated-steps call — if `current > 31` but
`previous_checksum` doesn't actually exist on `local_asset_entity`, real progress is clamped
back to 31 regardless of what the stored version claims, so the real v31→32→33→34 steps run for
real. `schemaVersion` was bumped 36→37 purely to force `onUpgrade` to fire again for devices
already stuck in the broken state (their stored version was already 36, so without a bump
`onUpgrade` wouldn't even run) — `from36To37` is a drift-tracked no-op, same pattern as
`from34To36`. Devices affected by build 129 self-heal automatically on the next launch after
updating; no reinstall or data loss. Covered by
`test/drift/main/v3_3_3_sync_regression_test.dart`, which simulates both the not-yet-broken
(stored v33) and already-broken (stored v36) device states against a real file-backed DB built
from the genuine v31 schema snapshot plus the old copyparty raw SQL, and asserts both repair to
a complete v37. **Lesson generalized: the pragma_table_info guard has to cover anything the
generated migration steps assume is already done, not just this fork's own raw-SQL columns** —
a renumbering collision can silently invalidate upstream's own steps just as easily.

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
| `bin/copyparty_test_harness.dart` | Standalone CLI test harness — runs `CopypartyUploaderService` directly against a real server (`dart run bin/copyparty_test_harness.dart --help`). Scenarios: `basic`/`resume`/`broken-pipe`/`all`. Needs its own delete-capable password via `--password`/`COPYPARTY_TEST_PASSWORD` (the in-app "Test harness password" debug setting only lives in the phone's secure storage, unreachable from this process — copy it over manually) |

Navigation note: `CopypartyImportPage` is NOT registered in `router.dart` (auto_route).
It is pushed directly: `Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CopypartyImportPage()))`.

Shared settings widgets note: `SettingGroupTitle`/`SettingListTile`/
`SettingsSubPageScaffold` (used by `copyparty_settings.dart`) moved from
`mobile/lib/widgets/settings/*.dart` into the `immich_ui` package
(`import 'package:immich_ui/immich_ui.dart';`) as of the v3.3.3 sync — check
that import path first if either of these ever goes missing again after a
sync, rather than assuming the class itself was renamed/removed.

### Local Flutter SDK also available (not just standalone Dart)
Beyond the standalone-Dart-for-`dart format` trick above, the FULL Flutter SDK is
also fetchable in this environment (`storage.googleapis.com` isn't blocked) —
enough for real `dart analyze`/`flutter pub get`, not just formatting:
```
curl -sS -o /tmp/flutter.tar.xz https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.2-stable.tar.xz
tar -xf /tmp/flutter.tar.xz -C /tmp/flutter-sdk   # ~1.5GB download, ~12GB extracted
git config --global --add safe.directory /tmp/flutter-sdk/flutter   # needed when running as root
export PATH="/tmp/flutter-sdk/flutter/bin:$PATH"
```
Check `mobile/pubspec.yaml`'s `environment.flutter` on every sync — it's bumped
almost every upstream release (3.47.2 as of the v3.3.3 sync), and
`build-custom-apk.yml`'s `flutter-version` must be kept in lockstep with it (a
mismatch fails `flutter pub get` in CI with "version solving failed"). Swap
the version in the curl URL above for whatever `pubspec.yaml` currently says.

As of v3.2.0 the openapi Dart client (`mobile/generated/openapi`, imported by
`mobile/pubspec.yaml` as a path dependency) is no longer checked in — it must be
generated before `flutter pub get` will resolve at all. **Pigeon-generated
platform code is also no longer checked in** (`lib/platform/*.g.dart`,
`android/**/*.g.kt`, `ios/**/*.g.swift` — upstream commit "remove Pigeon
generated code", landed in this same v3.1.0→v3.2.0 window): a fresh checkout
won't compile at all (`'NativeSyncApi' isn't a type`, etc.) until pigeon runs.
```
npm install -g @openapitools/openapi-generator-cli@2.41.0   # generate-dart-sdk.sh expects a real binary on PATH, not just npx — version must match the root mise.toml pin
cd open-api && bash ./bin/generate-dart-sdk.sh   # also needs java (both present here)
cd ../mobile && flutter pub get   # ~90s; run once per fresh session/container
dart run drift_dev make-migrations   # regenerates lib/data/db/main/database.steps.dart (gitignored)
dart run build_runner build          # routes, riverpod, freezed, drift entities
ls pigeon/*.dart | xargs -n1 -P4 -I{} dart run pigeon --input {}   # regenerates lib/platform/*.g.dart + native .g.kt/.g.swift
dart analyze --fatal-infos <files>   # matches CI's Dart Analysis check exactly
```
`build-custom-apk.yml` needs the same steps (global npm install, openapi
client, drift migrations, build_runner, pigeon) before `flutter build apk` —
it doesn't use mise, so each was added as its own workflow step; keep them in
that order if the DB, openapi spec, or a `pigeon/*.dart` file changes again.
(Build 124 shipped without the `npm install -g` step and failed CI with
`openapi-generator-cli: command not found` — the local sandbox had it on PATH
via a manual shim during testing, which masked the gap. Build 125 fixed that
but still omitted the pigeon step entirely — `dart analyze` passed locally
because `.g.dart` files were left over on disk from earlier manual testing,
but `flutter build apk` failed on a clean CI checkout with dozens of "isn't a
type" errors for every pigeon-generated class. Build 126 added the missing
step. Lesson: a local verification pass that reuses a dirty working tree can
hide a missing-codegen-step bug that only a truly clean checkout exposes —
CI's checkout is always clean, so re-verify against a state that mirrors that
when a "no code changed, just CI config" fix keeps failing.)

Previously-noted limitation now resolved: earlier sessions saw `flutter test` fail in this
sandbox with a `sqlite3` native-asset build-hook hash mismatch (`Bad state: Hash of downloaded
file libsqlite3...`). As of the build-130 fix verification, `flutter test` runs cleanly
end-to-end (confirmed: full suite + a new migration regression test using a real file-backed
`NativeDatabase`, ~1625 tests, all passing) — whatever proxy/environment artifact caused it
before is no longer present. Don't assume it's broken; try a real `flutter test` run before
falling back to analyze-only verification. (Plain `dart run <script>` — build_runner, drift_dev,
pigeon, easy_localization, the test harness — still won't work for anything that imports
`package:flutter/...` transitively, e.g. `database.dart`: it needs the Flutter engine, not just
the Dart SDK, so use `flutter test` for DB/migration-level checks instead of a bare `dart run`
script.)

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
