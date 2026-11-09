# Changelog

Versions are shown in the page header, `GET /healthz`, the start-up log line and the phone app's bridge tile
(header also shows the installed commit).

## 0.2.1 - watched folders follow the person

- *Folders & settings → Watched folders* now follows the person chosen at the top (or `?user=`). In folder-per-person
  mode each person's own folder is fixed (shown as "(their folder)", id hidden); you can add folders **inside** it
  (shown relative to it; the picker cannot leave it) and star one to import it first. Changes apply immediately, no
  Save, and adding a folder inside one the person already has does not pause them. Everyone lists each person's folder;
  the main account's folder is automatic. The server refuses extra folders outside a person's own folder.

## 0.2.0 - several people, folder per person

**What is new**
- **Several Immich accounts in one bridge** (People tab, header switcher): each person has their own API key, folders,
  import records and queue. A file goes to the owner of the most specific folder; for the shared area the uploader's
  copyparty login can decide. New people start paused; *Review & start* hands over files already imported elsewhere.
- **Folder per person**: folders named `<firstname>-<full Immich user id>` in the mounted data folder are detected
  automatically; add a person by picking the first name and pasting their key, and the bridge checks the key's account
  id against the folder name. Nothing to configure; `PEOPLE_ROOT=off` or the page's *Switch off* disables it.
- **Tab and person in the address**: `?t=status|people|settings|logs` opens that tab and `?user=ian` (id, name, Immich name or email) selects that person; clicking a tab or the switcher updates the address, so views can be bookmarked or shared. The folder-selection card is now "Debug folder selection" at the bottom of the People tab. In folder-per-person mode *Edit* shows only the key (name for the main account) and the folder as text, and has a *Remove person…* button.
- **Several copyparty containers** (`EXTRA_COPYPARTY=...`), explicit API-key errors that name missing permissions,
  `update-bridge.sh`, HTTPS-proxy notes.

**What behaves differently (read before updating)**
- *A single-person install needs nothing and behaves as before* (same `state.db`, same `/status` fields).
- With **two or more people**: `/hook` needs `BRIDGE_TOKEN`; the open `/status` shows totals only (no file names or
  errors; per-person detail needs the token); symbolic links out of a person's folder are no longer followed.
- With **folder per person on** (automatic when such folders exist in the data folder): the main account imports **only its own `name-<id>` folder**, no longer
  everything under the data folder; a folder nobody is set up for is imported by nobody; files directly in a person's
  folder get no folder album. Switching it off returns main to the installer's folders.
- New files on the state volume: `users.json` (holds every person's API key, plaintext, mode 600), `router.db`,
  `users/<id>/state.db`. Back them up with the volume; an unreadable `users.json` stops the bridge from starting.
- Environment variables belong between `|` and `bash` (`... install.sh | EXTRA_COPYPARTY=x bash`), not before `curl`.

**Updating**: `~/copyparty/update-bridge.sh` (add `BRANCH=<branch>` while this is not on the default branch).

## 0.1.0 - first release
Watches the copyparty data folder, imports into one Immich account (hook + periodic sweep), web page for settings,
folder albums, pause, account tracking, installer.
