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

## Moving the data folder

If you reorganise the share (for example moving the upload folders into a new parent folder), do the folder move
yourself first, then let `move-copyparty-root.sh` repoint everything that refers to it: copyparty's compose file and config, the
bridge, the bridge's saved folder settings and its memory of what it already imported (so nothing is re-hashed just
because a path changed). It never moves, copies or deletes your photos and videos, and it backs up every file it edits.

Run it on the Docker VM. Without `--apply` it only prints the plan:

```
curl -fsSL https://raw.githubusercontent.com/frostymccool/immich/feature/copyparty-up2k-import/copyparty-immich-bridge/move-copyparty-root.sh \
  | bash -s -- --data /mnt/uploads/Photos --app-folder Trips/Summer2026
```

To keep a copy on the VM instead of running it from the web each time (keep it in your copyparty folder, next to `docker-compose.yml`; it finds that folder by itself):

```
curl -fsSL -o ~/copyparty/move-copyparty-root.sh https://raw.githubusercontent.com/frostymccool/immich/feature/copyparty-up2k-import/copyparty-immich-bridge/move-copyparty-root.sh
chmod +x ~/copyparty/move-copyparty-root.sh
~/copyparty/move-copyparty-root.sh --data /mnt/uploads/Photos --app-folder Trips/Summer2026
```

A saved copy checks for the latest version every time it starts, replaces itself if there is a newer one and carries on
with that (offline, or a bad download, it just uses the copy it has; `MOVE_COPYPARTY_ROOT_NO_UPDATE=1` turns the check off).

When the plan looks right, add `--apply` to the end. It then prints the upload path to set in the phone app, and how to
undo it (`--rollback <backup folder> --apply`). If the share is a network mount (cifs/nfs), it also moves copyparty's
index database onto the VM's own disk, because sqlite cannot lock files on those shares (copyparty then shows
`database is locked` and switches its upload index off). After a move copyparty re-indexes the folder, and uploads pause
until that finishes.

## Folder per person (no folders or logins to type)

If copyparty gives every person their own folder named **`<firstname>-<their Immich user id>`** (the full id, e.g.
`leza-3f2a9c1e-7b4d-4e0a-9d21-1c8e5a6b91c2`) inside one folder (say the network share `/mnt/picsupload`), the bridge can
work out the rest:

1. **There is nothing to turn on.** The bridge looks in the mounted data folder, and as soon as it finds folders named
   like that, folder-per-person is ON (the People tab says "ON (found automatically)"). It switches itself on when the
   first such folder appears. If your folders live deeper, use *Advanced: use a specific folder* on the People tab (or
   install with `PEOPLE_ROOT=Share/People`; a path is relative to the copyparty data folder, `.` = the folder itself).
   `PEOPLE_ROOT=off` (or *Switch off* on the page) disables it; `PEOPLE_ROOT=none` forgets a remembered folder and goes
   back to automatic. Re-runs and `update-bridge.sh` remember it.
2. **Add a person:** in the *Add a person* section pick their first name from the dropdown (the id is not shown; if two
   people share a first name the last 4 digits of the id are shown to tell them apart) and paste **their own** Immich API
   key. *Test key* confirms the key belongs to the exact Immich account whose full id is in the folder name. A key from a
   different account is refused and the message says so (naming only the last 4 digits of each id). No folder or login
   fields are shown in this mode (they are only under "Add by hand instead" when no such folders exist).
3. They start paused; **Review & start** as usual.

What changes in this mode:
- The **main account imports only its own folder** (`<name>-<its id>`), found by asking Immich whose key it is. Until
  Immich has answered, main imports nothing. It no longer imports "everything under the data folder".
- A folder that matches **nobody** (not named `name-<id>`, or nobody set up for that id yet) is imported by **nobody**
  and is listed in the dropdown note ("Ignored …"). Files loose in the people folder itself are ignored too.
- No folder or copyparty-login fields: the folder *is* the identity. (Logins still work for people added the old way.)
- Files directly in a person's folder get no folder album (the album would be named after the id); files in
  subfolders still get an album named after that subfolder.
- A person's key can only ever be replaced by a key of the **same** Immich account.
- Folders still have to be created on the copyparty side, with copyparty permissions so each person can write only
  their own folder; the bridge does not manage copyparty accounts.
- Moving existing files: put them into the person's folder and press *Review & start* (see above).
- **Safety rules from the review:** a symlink in the people folder is never a person's folder (it could point at
  somebody else's photos); the main account's own folder is found only from Immich's *current* answer (an id
  remembered from an earlier run is never used, and until Immich answers main imports nothing); if a person's key
  later resolves to a different Immich account than their folder is named for they are **held**; inside the people
  folder a person can only ever have folders named for their own account; the saved people folder is kept even if
  the share is not mounted at boot (then nothing imports, rather than the main account taking the whole tree).
- **Switching it off** sends main back to the installer's folders, so any folder under them that nobody was set up
  for is then imported into the *main* account (the page warns you first).
- A setting saved on the page (Switch off / a specific folder) wins over `PEOPLE_ROOT` from the installer (same rule as every other page setting;
  the bridge log shows the value in effect at startup). The folder names (with the full id) are visible to anyone
  with the bridge token via the API; the page itself shows only the last 4 digits.

## More than one person (several Immich accounts)

One bridge can import for several people, each into **their own Immich account**. Nothing changes for a
single-person install: with nobody added, the bridge behaves exactly as before.

**1. Give each person their own Immich account and API key.** In Immich: create the user, log in as them,
Account Settings → API Keys → new key ("all permissions" is simplest; without album permissions imports still work
but folder albums do not). Two people can never share one Immich account (the bridge refuses it). The key must have at least `user.read` and
`asset.upload` (or "all"); *Test key* names exactly which permissions a key is missing. Without `album.read`,
`album.create` and `albumAsset.create` imports work but folder albums do not (also listed).

**2. Decide where their files live.** Either one copyparty with a folder per person (`/w/alex`, `/w/sam`), or a
second copyparty container with its own data folder:

```
curl -fsSL https://raw.githubusercontent.com/frostymccool/immich/feature/copyparty-up2k-import/copyparty-immich-bridge/install.sh | EXTRA_COPYPARTY=copyparty-sam bash
```

That mounts the second copyparty's data folder into the bridge at `/cp/copyparty-sam` (read-only unless
`WRITABLE=1`; several: `EXTRA_COPYPARTY=a,b`; a container with several data mounts: `a=/host/folder`;
`EXTRA_COPYPARTY=none` forgets them). Re-runs and `update-bridge.sh` remember the list. It refuses two copyparty
containers whose data folders are the same or nested (one file would have two owners). For *instant* import from
the second copyparty its own compose file needs the hook too; the installer prints the exact lines
(`IMMICH_BRIDGE_SOURCE` names that container so its paths are translated correctly; the printed block holds the
token, so keep that compose file private). It never edits another compose
project. Without the hook the periodic scan still imports everything, up to 15 minutes later.

**3. Add the person on the settings page → People tab.** Name, their API key (press *Test key* to see which Immich
account it is), their folder(s) (*Choose folder…*), optionally their copyparty login. They start **paused**.

**4. Press *Review & start*.** It shows how many files in their folder were already imported into somebody else's
account (typically the main one, from before this person existed) and says what will happen: those import records
are handed over, the files are imported again into *their* account, and the copies already in the other account
stay where they are (the bridge never deletes in Immich). Confirm and they start.

**Who gets a file?** The person whose folder it is in (the most specific folder wins). A file in the *shared* area
(the main account's folders) goes to the person whose copyparty login uploaded it, if you entered that login;
otherwise it stays with the main account. A login never pulls a file out of somebody else's folder, and a file
that is in nobody's folder is *not imported* and is listed on the People tab so it is not silent.

**Moving the files you already have.** Old files carry no record of who uploaded them, so the bridge cannot sort
them by login. Move them into each person's folder yourself (copyparty or the file manager), then press *Review &
start* (or *Re-check files*) on that person.

**Header switcher.** With two or more people a selector appears at the top: *Everyone* (totals) or one person
(their status, recent files, albums, pause, re-import). The *Folders & settings* tab still holds the shared
settings and the main account's folders.

**Removing a person** (People → Remove…, type their id): the bridge stops importing for them and forgets its own
records for them; their folders go on a "Folders nobody imports" list so their files do **not** quietly flow into
the main account. Nothing is deleted in Immich or on disk. *Give back to the main account* undoes the ignore.

**Folders changed?** Changing a person's folders pauses them again until you press *Review & start*, and a folder
taken away from them goes on the "Folders nobody imports" list (so it does not drop into the main account).
*Resume* refuses while files in their folders were already imported by somebody else: use *Review & start*.

**Pause.** With *Everyone* selected the header button pauses/resumes everybody; with a person selected, only them.

**Held people.** A person is shown as *held* when two people resolve to the same Immich account, or while the
bridge cannot yet reach Immich to confirm whose key it is. Fix the key (Edit) or wait; nothing is imported into a
wrong account meanwhile.

**Good to know**
- One admin token manages everybody (there are no per-person logins to the page). Anyone with the token can see
  every person's file names and replace their API key; keys can never be read back out.
- Keys are stored in `/data/users.json` on the state volume (plaintext, mode 600, like `immich-bridge.env`). Back
  that file up with the state volume. Uninstalling keeps that volume; `docker volume rm copyparty_bridge-state`
  removes the keys too. If it ever cannot be read the bridge **refuses to start** rather than guess.
- With several people `/hook` needs the token (the installer always sets one); the open `/status` the phone reads
  shows totals and no file names.
- Each person has their own import workers (`WORKERS`, default 1, per person), so uploads run side by side.
- With several people, symbolic links are not followed out of a person's folder (so nobody can link to somebody
  else's photos).
- Not covered: per-person tokens, per-person post-import action / sweep interval, moving files on disk for you.
- Tested with fake Docker and a fake Immich only; the cross-container hook path (second copyparty → bridge) needs
  a manual check: upload a file as the second copyparty's user and watch the bridge log for `queued (hook)`.

## Using an HTTPS name (reverse proxy)

The bridge itself only speaks plain HTTP on its port. If you put a LAN reverse proxy in front of it
(for example `https://bridge.example.com` → `http://192.168.1.50:8099`):

- **Open the page** at `https://bridge.example.com/#token=<token>` (the token is in `immich-bridge.env`).
- **Phone app:** Settings → copyparty → Import Bridge → URL `https://bridge.example.com`. The app only reads
  `/healthz` and `/status`.
- **Leave copyparty's hook alone.** It talks to the bridge directly over Docker
  (`IMMICH_BRIDGE_URL=http://immich-bridge:8099`), so it does not go through the proxy. Do not expose `/hook`
  or the bridge to the internet; keep the name LAN-only (or behind a VPN/login). The token is the only protection
  on `/api/*`, and it can manage every person's Immich key.
- The proxy needs no special settings (no websockets); pass the `X-Bridge-Token` header through unchanged.
- Your real domain and addresses belong in your proxy config only, never in this repository.

## Update, remove, options

| Want | Do |
|------|----|
| (how options work) | every option below is an environment variable placed between the `|` and `bash`, e.g. `… install.sh \| WIDE=1 bash`. In front of `curl` it would be silently ignored |
| Update to the latest | run `~/copyparty/update-bridge.sh` (saved there by the installer; it first makes sure it is itself the latest, then runs the latest installer, which reuses your key, token and folders). `--check` only says whether a newer version exists. Running the install command again does the same |
| Uninstall | same command ending `\| bash -s -- --uninstall` |
| Choose the app folder without being asked | prefix `APP_FOLDER=Trips/Other` (`APP_FOLDER=.` = everything); `BASE_FOLDER=Trips` overrides what `WIDE=1` watches |
| Skip the instant hook | prefix `HOOK=0` |
| Let the page enable move/delete after import | prefix `WRITABLE=1` (mounts the data read-write) |
| Change the port | prefix `BRIDGE_PORT=9000` |
| Non-default paths | `COPYPARTY_DIR=/path` `CONTAINER=name` `IMMICH_URL=http://host:2283` |
| Key without a prompt | prefix `IMMICH_API_KEY=xxxx` |
| More copyparty containers | prefix `EXTRA_COPYPARTY=name` (see "More than one person"). If a remembered one is later removed, updates just drop it with a note |

If something fails it stops with a plain message (and the bridge log) before changing your
setup further. Logs afterwards: `docker logs immich-bridge`.

## Settings saved on the page vs. the installer

The installer sets the starting folders. Anything you save on the settings page is kept on the
bridge's state volume and **wins** over the installer's values from then on (re-running the
installer will not undo it). **Reset to installer defaults** on the page removes your saved
settings. The token is created once and reused by re-runs, so your browser link keeps working.
