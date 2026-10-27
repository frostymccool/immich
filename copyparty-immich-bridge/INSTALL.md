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

The folder your phone app uploads into, imported first. **The installer asks for it once, and shows you the
folders that actually exist** (newest first, so the one you just uploaded into is usually number 1): type its
number, or type a path, or just press Enter to watch everything. It **remembers your answer on every re-run**,
so updating never asks again. Nothing else on the NAS is touched, so the first run can't surprise you. To also
import the rest of the folder that contains it (anything Immich doesn't already have, deduplicated by checksum),
re-run with `WIDE=1`:

```bash
curl -fsSL https://raw.githubusercontent.com/frostymccool/immich/feature/copyparty-up2k-import/copyparty-immich-bridge/install.sh | WIDE=1 bash
```

You can change the watched folders any time on the settings page (no re-install needed).
Source files are never moved or deleted (the bridge mounts them read-only).

## "I can't see the files / albums in Immich"

Everything the bridge imports, and every album it creates, belongs to **the Immich account the API key was
created under**. If you browse Immich as a different user, you will see none of it. The bridge's Status tab now
says which account that is ("Importing into the Immich account …") and lists the folder albums it has used, each
as a link that opens in Immich. Fix: create the API key while logged in as the account you actually use, and
re-run the installer with `IMMICH_API_KEY=… ` in front (or share the albums with your account in Immich).

Files imported **before** you switched keys are in the old account, and the bridge remembers them as done. If the
bridge notices the key now belongs to a different account, the Status tab shows an amber notice with a button
**Re-import everything into the new account**; the same button lives on the Folders & settings tab
(**Re-import everything…**). It makes the bridge forget what it imported and import everything again into the
account the key belongs to now. Nothing on the NAS or in Immich is changed or deleted, files the new account already
has are recognised as duplicates, and it re-uploads over your network, so it can take a long time. Files the bridge
moved or deleted after importing (`POST_IMPORT_ACTION`) cannot be imported again.

## Pausing

The **Pause imports** button (top right of the settings page) stops new imports so you can check what has been
done; **Resume imports** carries on. New uploads keep being queued meanwhile. The pause survives restarts.
(`docker stop immich-bridge` also works as a hard stop.)

## Albums

Every imported file is also added to an Immich album named after the folder it sits in (a file in
`Day 3 hike/` goes into the album **Day 3 hike**, which is created the first time it is needed). Switch it off with the
checkbox on the settings page, or `ALBUM_FROM_FOLDER=false`.

**Needs an Immich API key with album permissions** (`album.read`, `album.create`, `albumAsset.create`, or simply
*all permissions*). The installer checks the key and prints a note if it lacks them, and the bridge's Status tab
shows a red banner (and the Logs tab a warning) if albums can't be written, so it can't fail silently. Imports
themselves never depend on it. To fix a key: create a new one in Immich (Account Settings > API Keys, all
permissions) and re-run the installer with `IMMICH_API_KEY=… ` in front.

**Files imported earlier** (before albums were on, or while the key lacked permission) are added by the button
**Add already-imported files to their folder albums** on the Folders & settings tab. Safe to press again.

## Update, remove, options

| Want | Do |
|------|----|
| Update to the latest | run the same command again (it reuses the saved key) |
| Uninstall | same command ending `\| bash -s -- --uninstall` |
| Choose the app folder without being asked | prefix `APP_FOLDER=Trips/Other` (`APP_FOLDER=.` = everything); `BASE_FOLDER=Trips` overrides what `WIDE=1` watches |
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
