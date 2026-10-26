# copyparty → Immich bridge

A small standalone Docker service that auto-imports media uploaded to a
[copyparty](https://github.com/9001/copyparty) server into
[Immich](https://immich.app). Anything any device uploads to the watched
copyparty volume — phone, laptop, camera workflow — shows up in Immich
automatically, deduplicated by content checksum.

Designed to run next to the existing copyparty and Immich containers on the
same host (e.g. a Proxmox VM), sharing copyparty's data volume read-only.

## How it works

```
uploader ──► copyparty ──(xau event hook: JSON POST)──► bridge ──(Immich API)──► Immich
                 │                                        ▲
                 └── shared volume (read-only) ───────────┘  + periodic sweep
```

1. **Instant path** — copyparty's `xau` (execute-after-upload) event hook runs
   a tiny forked script that POSTs the upload's JSON (`ap`, `sz`, `mt`, …) to
   the bridge's `/hook` endpoint. Forked = uploads are never blocked, hook
   failures never hurt copyparty.
2. **Reliable path** — the bridge also sweeps the watched directory tree on
   startup and every `SWEEP_INTERVAL_SECONDS`, so files uploaded while the
   bridge was down (or before it existed) are still imported. `.hist`,
   dotfiles and in-progress `*.PARTIAL` uploads are excluded; files must be
   older than `MIN_FILE_AGE_SECONDS` so nothing is grabbed mid-write.
3. **Import** — for each candidate file the bridge:
   - checks the extension against Immich's own `GET /api/server/media-types`
     (so "compatible" always matches your Immich version; override with
     `INCLUDE_EXTENSIONS`),
   - streams a SHA-1 and asks `POST /api/assets/bulk-upload-check` — content
     already in Immich (e.g. already backed up by the phone app) is recorded
     as a duplicate and skipped,
   - otherwise uploads via `POST /api/assets` (with the `x-immich-checksum`
     header so a concurrent upload of the same bytes is also handled),
   - adds the asset to an album named after its folder (`ALBUM_FROM_FOLDER`, on by default; created on demand) and, optionally, one fixed album (`IMMICH_ALBUM_NAME`),
   - applies the post-import action (`keep` / `move` / `delete`, default `keep`),
   - records the outcome in a SQLite state DB (`/data/state.db`) so nothing is
     re-hashed or re-imported unless the file's size/mtime changes.
   Failures are retried on later sweeps, up to `MAX_ATTEMPTS` per file version.

## Setup

**Easiest: run the one-line installer in [INSTALL.md](INSTALL.md)** (finds your copyparty, builds and
starts the bridge, asks only for the Immich API key). The manual steps below are for reference.

1. Create an API key in Immich: **Account Settings → API Keys**.
2. Mount copyparty's data directory into the bridge **at the same container
   path** copyparty sees, read-only (see `docker-compose.example.yml`). If the
   paths must differ, set `PATH_MAP=/copyparty/prefix=/bridge/prefix`.
3. Mount `hook/immich_bridge_hook.py` into the copyparty container and add the
   event hook to copyparty's flags, globally:

   ```
   --xau f,j,t30,/hooks/immich_bridge_hook.py
   ```

   or per-volume (volflag): `-v /w/uploads:uploads:rw,ed:c,xau=f,j,t30,/hooks/immich_bridge_hook.py`

   Set `IMMICH_BRIDGE_URL=http://immich-bridge:8099` on the copyparty
   container. The hook is optional — without it imports simply wait for the
   next sweep.
4. `docker compose up -d --build` and watch `docker logs immich-bridge`.

## Configuration (environment variables)

| Variable | Default | Purpose |
|----------|---------|---------|
| `IMMICH_URL` | *(required)* | Immich server base URL, e.g. `http://immich-server:2283` |
| `IMMICH_API_KEY` / `IMMICH_API_KEY_FILE` | *(required)* | Immich API key (or a file containing it, for secrets) |
| `WATCH_DIRS` | *(required)* | Comma-separated directory paths (as mounted in the bridge) to watch |
| `PRIORITY_DIRS` | *(empty)* | Comma-separated folders **inside `WATCH_DIRS`** imported first (e.g. the folder the phone app uploads into). Everything else under `WATCH_DIRS` is still imported, just after. Empty = no preference |
| `PATH_MAP` | *(empty)* | `src=dst[,src=dst]` prefix rewrites from copyparty's paths to the bridge's |
| `SWEEP_INTERVAL_SECONDS` | `900` | Reconciliation sweep period; `0` = sweep once at startup only |
| `MIN_FILE_AGE_SECONDS` | `30` | Sweep ignores files modified more recently than this |
| `MAX_ATTEMPTS` | `5` | Retry budget per file version before giving up |
| `POST_IMPORT_ACTION` | `keep` | `keep`, `move` (to `MOVE_SUBDIR`), or `delete` — move/delete need a `rw` mount |
| `MOVE_SUBDIR` | `.imported` | Subfolder (next to the file) used by `move` |
| `ALBUM_FROM_FOLDER` | `true` | Add every imported file to an Immich album named after the folder it sits in (e.g. `Day 3 hike/IMG_1.jpg` → album `Day 3 hike`), created on demand. Only the immediate folder is used; hidden folders are ignored. `false` turns it off |
| `IMMICH_ALBUM_NAME` | *(empty)* | If set, imported assets are ALSO added to this one fixed album (created on demand) |
| `INCLUDE_EXTENSIONS` | *(empty)* | Comma-separated extension allow-list; empty = ask Immich |
| `STATE_DB` | `/data/state.db` | SQLite state DB path |
| `BIND_HOST` / `BIND_PORT` | `0.0.0.0` / `8099` | Hook/status HTTP listener |
| `DEVICE_ID` | `copyparty-immich-bridge` | `deviceId` reported to Immich |
| `IMMICH_VERIFY_TLS` | `true` | Set `false` for self-signed Immich certs |
| `WORKERS` | `1` | Parallel import workers (1 is right for most setups) |
| `LOG_LEVEL` | `INFO` | `DEBUG` for per-request detail |
| `BRIDGE_TOKEN` | *(empty)* | Secret for the web page / `/api/*` and for `/hook`. **Empty = the settings API is switched off** and `/hook` stays open (old behaviour). The installer generates one |
| `BROWSE_ROOTS` | *(empty)* | Folders the web page's folder picker may list, and watched folders must sit inside (the installer sets it to copyparty's data mount). Empty = no folder picker |
| `SETTINGS_FILE` | `/data/settings.json` | Where settings saved from the web page are kept (on the state volume) |

## Web page (settings, folder picker, status, logs)

Open `http://<vm>:8099/` (the installer prints a link with the token in it). Everything below
is behind `BRIDGE_TOKEN`:

- **Status** — counts, queue, recent files with errors.
- **Folders & settings** — add/remove several watched folders with a folder picker, star the
  ones imported first, scan interval, file-age guard, retry budget, post-import action, folder-named albums, one fixed album,
  allowed file types, log detail. Changes apply **immediately, no restart**, are validated
  first (nothing is applied if any field is wrong) and are saved on the state volume.
  Saved values win over the compose/env values until you press **Reset to installer defaults**.
- **Logs** — live tail with level + text filter and a **Download log** button (last 2000 lines
  since the container started; `docker logs immich-bridge` for older history).
- **Scan now** — runs the sweep immediately.

What the page deliberately cannot change (needs a compose change or restart): the Immich
URL and API key, the port, the worker count, and which host folders are mounted. A container
cannot see the host filesystem beyond what is mounted into it, so the folder picker lists
only what is mounted (the installer mounts copyparty's whole data root). To add a folder from
somewhere else, add a volume mount and re-run the installer. To change the port re-run the
installer with `BRIDGE_PORT=9000`. `move`/`delete` after import also need the data mounted
read-write (installer option `WRITABLE=1`); the page refuses them while it is read-only.

## Endpoints

- `POST /hook` — copyparty event receiver (single JSON object, or a list for
  `xiu` batch hooks). Needs the token when `BRIDGE_TOKEN` is set
- `GET /status` — counters by status, queue depth, watch/priority dirs, album health (`albums`: key permission check, added/failed counts, last error, back-fill progress), 20 most recent items (open; the phone app reads it)
- `GET /healthz` — liveness (open)
- `GET /` — the web page (the page itself is public; all data behind it needs the token)
- `GET|PUT /api/config`, `POST /api/config/reset`, `GET /api/fs?path=`, `GET /api/logs`,
  `GET /api/logs/download`, `POST /api/scan`, `POST /api/albums/backfill` (add everything already imported to its folder album), `POST /api/albums/recheck` (re-test the key's album permissions) — the web page's backend. Send the token as
  `X-Bridge-Token: <token>` or `Authorization: Bearer <token>`

## Notes & limits

- **Safety**: files are only moved/deleted *after* Immich has confirmed the
  content (fresh upload or checksum duplicate). Default is to touch nothing.
- Sidecar files (`.xmp`) are not imported standalone (Immich doesn't accept
  them without their asset); they're recorded as skipped.
- The state DB is authoritative for "already imported" — deleting an asset in
  Immich will not cause a re-import unless you also clear the DB row (or the
  file's mtime changes). This is deliberate: it makes deleting from Immich safe.
- The bridge never writes to copyparty's `.hist` or interferes with up2k;
  it only ever reads completed files (and moves/deletes them if you opt in).

## Development

```
python3 -m pytest tests/          # unit + stub-server integration tests
```
