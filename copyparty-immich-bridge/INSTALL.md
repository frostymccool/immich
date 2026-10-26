# Install the copyparty → Immich bridge

Run this **on the VM that runs your copyparty container** (as the user that owns `~/copyparty`):

```bash
curl -fsSL https://raw.githubusercontent.com/frostymccool/immich/feature/copyparty-up2k-import/copyparty-immich-bridge/install.sh | bash
```

It asks for one thing: an **Immich API key** (Immich web → Account Settings → API Keys →
create one with all permissions, paste it when prompted; input is hidden). Everything else is
detected or defaulted:

- finds your copyparty container and data mount automatically
- checks Immich is reachable and the key works *before* changing anything
- downloads the bridge, builds it, starts it, and waits until it is healthy
- adds the instant-import hook to copyparty (falls back to a 15-minute sweep by itself if
  copyparty won't start with it)
- **never edits your `docker-compose.yml`** — it writes a separate `docker-compose.override.yml`

When it finishes it prints two links:

1. **Settings page** `http://<vm-ip>:8099/#token=…` — open it once in a browser (the browser
   remembers it). There you choose the folders to watch with a folder picker (several are fine),
   change behaviour, read the logs, download them and press **Scan now** — no restart, no editing files.
2. **On your phone:** Settings → copyparty → Import Bridge → URL `http://<vm-ip>:8099`
   (the tile then shows running / counts / last activity and which folders it watches, and has an
   "Open settings page" button).

## What it watches by default

Only the app's upload folder, `Australia/Asia2026` (imported first). Nothing else on the NAS is
touched, so the first run can't surprise you. To also import the rest of `Australia` (anything
Immich doesn't already have, deduplicated by checksum), re-run with `WIDE=1`:

```bash
curl -fsSL https://raw.githubusercontent.com/frostymccool/immich/feature/copyparty-up2k-import/copyparty-immich-bridge/install.sh | WIDE=1 bash
```

Source files are never moved or deleted (the bridge mounts them read-only).

## Update, remove, options

| Want | Do |
|------|----|
| Update to the latest | run the same command again (it reuses the saved key) |
| Uninstall | same command ending `\| bash -s -- --uninstall` |
| Different folder names | prefix `APP_FOLDER=Australia/Other BASE_FOLDER=Australia` |
| Skip the instant hook | prefix `HOOK=0` |
| Let the page enable move/delete after import | prefix `WRITABLE=1` (mounts the data read-write) |
| Change the port | prefix `BRIDGE_PORT=9000` |
| Non-default paths | `COPYPARTY_DIR=/path` `CONTAINER=name` `IMMICH_URL=http://host:2283` |
| Key without a prompt | prefix `IMMICH_API_KEY=xxxx` |

If something fails it stops with a plain message (and the bridge log) before changing your
setup further. Logs afterwards: `docker logs immich-bridge`.

## Settings saved on the page vs. the installer

The installer sets the starting folders. Anything you save on the settings page is kept on the
bridge's state volume and **wins** over the installer's values from then on (re-running the
installer will not undo it). **Reset to installer defaults** on the page removes your saved
settings. The token is created once and reused by re-runs, so your browser link keeps working.
