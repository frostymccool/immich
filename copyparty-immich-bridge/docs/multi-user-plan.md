# Multi-user bridge: blueprint

Status: IMPLEMENTED (build 242). Written before any code, revised after a three-persona review (security, data
integrity, operations/UX); a second review of the code followed. "Revision 2" at the end lists what the review changed.

## Goal

One bridge container imports files for **several Immich accounts**. The files can come from
**one copyparty with a sub-folder per person** or from **several copyparty containers**.
A single-user install (today's) must keep working byte-for-byte: no new required settings,
same `state.db`, same page, same `/status` shape.

## Decisions taken with the owner

| Question | Answer |
|---|---|
| Architecture | One bridge, many users (not one container per user). |
| How a file finds its owner | By **copyparty login** (hook field `user`), with the **folder** as the fallback for the sweep and for old files. |
| Existing files | Moved to each user's location once the locations are set up (see "Adopting existing files"). |
| Several copyparty containers | The bridge mounts each copyparty's data folder. |
| Web page | User switcher in the header, ONE admin token. |

Verified against copyparty's source (`util.py::_runhook`): the xau JSON holds `ap`, `vp`, `host`,
`user` (the login, `*` when anonymous), `perms`, `src` (copyparty's hook name), `sz`, `mt`, `ip`.

## Model

* **User** = Immich account + where its files live.
  `id` (slug, immutable), `name`, `api_key` (secret), `folders[]` (absolute, inside BROWSE_ROOTS),
  `priority_dirs[]`, `cp_logins[]`, `album_name`, `album_from_folder`, `paused`, `enabled`.
* **Main user** (`id = main`) is today's single account, still fed by `IMMICH_API_KEY` / `WATCH_DIRS`
  / `PRIORITY_DIRS` and the existing `settings.json`. Only its `name` and `cp_logins` live in the new file.
  It is the **catch-all**: a file nobody else owns belongs to it.
* **users.json** (`/data/users.json`, mode 0600, atomic write) holds the extra users. API keys are
  never returned by any endpoint (only `api_key_set` and the last 4 characters).
* Everything else (sweep interval, file-age guard, retries, post-import action, extensions, log level,
  workers, global pause) stays **global**.

## Who owns a file (`Router.owner(path)`, one function, used by every path)

1. A **claim** (`claims` table: path -> user id) if that user still exists and is enabled.
2. Otherwise the **longest matching folder** among all users' folders (main's `watch_dirs` included).
3. Otherwise nobody: the file is ignored (not in any watched folder).

Claims are created only by the hook, only when the uploader's login maps to exactly one user, and only
for a path inside some watched folder that is **not** inside another user's explicit folder
(folder beats login: copyparty permissions normally keep people in their own folder, and a
misconfigured login must not push files into somebody else's account). Claims are what make the
instant (hook) path and the later sweep agree. Deleting a user drops its claims.

Why not "login only": the sweep and old files have no uploader information on disk, and the same
file must never be imported into two accounts.

## Per-user isolation

Each user gets its own `ImmichClient`, `StateStore`, `ImportWorker` (queue, album cache, account
tracking, back-fill, progress). Main keeps `/data/state.db`; others use `/data/users/<id>/state.db`.
`UserView` is a thin proxy over the global `Config` that overrides only the per-user fields,
so global setting changes still apply live. Worker code changes are limited to: "is this path mine"
(`router.owner(path) == me`) replacing "is this path in watch_dirs", and the sweep including this
user's claimed paths.

## Hook (`POST /hook`)

Unchanged payload. New optional fields read by the bridge: `user` (login) and `bridge_source`
(set by the hook script from `IMMICH_BRIDGE_SOURCE`, names the copyparty container). Paths are
translated with that source's map (`SOURCE_MAPS`), else the global `PATH_MAP`. A path outside every
watched folder is still ignored. A malformed/unknown login never errors: it falls back to folder.

## API (all behind the admin token, as today)

* `GET /api/users` list (masked keys, Immich account, queue, counts, warnings)
* `POST /api/users` create. The key is checked against Immich first (`/users/me`); the same Immich
  account as an existing user is refused (it would double-import).
* `PUT /api/users/<id>` edit (key only changes when a new one is sent).
* `DELETE /api/users/<id>` with `{confirm:true}`; removes the user, its claims and its bridge records.
  Never touches files or anything in Immich.
* `POST /api/users/<id>/adopt` see below.
* `POST /api/users/check` test a key without saving.
* Existing endpoints take `?user=<id>` (default `main`): `/status`, `/api/config` readonly block,
  `/api/pause`, `/api/reimport`, `/api/account/ack`, `/api/albums/*`. `/status` **without** `user`
  returns the aggregate (summed counts and queue) so the phone tile keeps working; it never lists
  names, emails or keys (it is the open endpoint).

## Adopting existing files ("move the current files")

Old files have no uploader on disk, so they cannot be attributed by login. When a user's folder is
set up, **Adopt** (`POST /api/users/<id>/adopt`) does, for every file under the user's folders:
drop any claim, drop the previous owner's import record, and queue it for this user. By the folder
rule it now belongs to the new user; it is imported into their Immich account (Immich de-duplicates
per account, so nothing is duplicated within an account). Copies already in the previous owner's
Immich are NOT removed (the bridge never deletes in Immich). The owner moves the files on disk
themselves (copyparty/file manager); the dry-run preview shows how many records would move.

## Installer (several copyparty containers)

`EXTRA_COPYPARTY=name1,name2` (container names). For each: find its data mount (same rules as
today), mount it read-only at `/cp/<name>` in the bridge (`WRITABLE=1` -> rw), add it to
BROWSE_ROOTS, record `SOURCE_MAPS: <name>|<copyparty-internal-path>=/cp/<name>`. The hook for an
extra container is written as an override **in that container's own compose project directory**
(from the `com.docker.compose.project.working_dir` label) only if no foreign override exists
there; it posts to `http://<host-ip>:<port>` (different compose projects do not share a network)
and sends `IMMICH_BRIDGE_SOURCE=<name>`. Otherwise sweep-only, with a clear message.
Re-runs keep the list (read from the override, like APP_FOLDER).

## Web page

* Header: user switcher (hidden while there is only the main user, so single-user installs look
  the same). It scopes Status, the account/album/re-import cards and pause.
* New **Users** tab: cards (name, Immich account, folders, logins, queue, state), Add / Edit /
  Remove, "Test key", "Adopt files". Keys are write-only fields.
* "Folders & settings" stays global + main account.

## Tests

Unit: router (longest prefix, claims, disabled users, folder-beats-login, anonymous `*`), users store
(validation, atomic write, 0600, masked output, id slugs, duplicate folders, duplicate Immich account),
UserView proxy, worker ownership (nested folders, claims swept), adopt, state isolation, API (auth,
masking, scoping, aggregate `/status`), hook (login routing, source map, outside folder),
installer with fake docker (extra copyparty), backward compatibility (no users.json = unchanged).
Browser: Playwright against a real server with two fake Immich servers.

## Not in scope / known limits

* Per-user web tokens (one admin token).
* Per-user post-import action, extensions, sweep interval.
* Moving files on disk.
* Everything Docker-related is untested against real Docker (fake docker only).

## Revision 2: what the first review changed (all adopted unless noted)

Security
* **Symlinks**: with more than one person, a symlinked file is refused and a file's real path must stay inside the
  owner's real folder (`Router.owner`). Ownership is re-checked right before upload and before any post-import
  move/delete.
* **Hook**: with more than one person `/hook` is refused without `BRIDGE_TOKEN`. `bridge_source` only selects a path
  map; an unknown source is ignored (it does not fall through to the global `PATH_MAP`). A claim can only move a file
  out of the main account's catch-all, never out of another person's folder.
* **Open `/status`**: with several people it shows totals only (no `recent`, no paths/errors); the single-user output
  is unchanged. Per-person recent files need `?user=` (still the open endpoint, as before for the one person).
* **Keys**: never returned (not even the last 4 characters); `users.json` is created 0600 via `os.open` + fsync +
  atomic replace; per-person state directories 0700; ids are `[a-z0-9-]{1,32}` and `main`/reserved names refused.
* **Destructive actions**: remove needs the typed id; adopt needs the preview's number echoed back (409 if it
  changed); `main` cannot be removed.
* Not adopted: per-source hook tokens (one token; documented), rate limiting beyond the existing delay.

Data integrity
* New people start **paused**; adopt (the preview + confirm) is the single "review, then start" path.
* A removed person's folders go on an **ignore list** so their files never fall into the main account; a disabled or
  paused person still owns their folders.
* A corrupt `users.json` stops the start (exit 2) instead of acting as "no people".
* Claims live in `/data/router.db` (never in `state.db`, which is untouched), are tied to (size, mtime), and are
  collected when the file is gone. Reimport does not clear them.
* One owner function; the sweep prunes other people's folders from the walk and re-checks ownership per file; the
  sweep also retries a person's claimed files that sit outside their folders.
* Hot remove: stop, join (up to 30 s), then close the store. A new person is held (`blocked`) until Immich has said
  which account their key is; two people on one account are held at startup, edit and add.
* Per-person `WORKERS` (documented multiplication).

Operations / UX
* Installer: extras are mounted/mapped and remembered (comment line in the override); a re-run with no variables is
  byte-identical (tested); overlapping or nested data folders refused; unknown container refused by name; the hook
  for extra containers is **printed, not written** into another compose project (default sweep-only otherwise).
* Page: People tab with plain-language states (paused, held, key rejected, albums off, folder missing, key moved
  account), unassigned-files banner, switcher hidden for one person, Everyone view = totals.
* Docs: INSTALL.md "More than one person" with a manual checklist for the cross-container hook.

## Revision 3: folder-per-person (owner request, build 245)

Owner's layout: one shared folder (e.g. a network mount) holding `<firstname>-<full Immich user id>` folders.
Decisions (asked + answered): full UUID in the folder name; a folder that matches nobody is imported by nobody; main
(the installer's key) imports only its own `name-<its id>` folder; Add person = dropdown of first names + paste key.

* `bridge/people.py`: `parse_folder` (`name-<uuid>`, hyphenated names ok, uuid lower-cased), `PeopleLayout`
  (3-second scan cache, `main_dirs()` = only the folder whose id equals main's id, nothing while main's id is unknown).
* The id binding: `POST /api/users {people_folder, api_key}` probes the key (permissions + whoami), requires
  `whoami.id == id in the folder name`, stores `immich_id` on the person, and refuses a later key of another account.
* The router needs no new concept: main's roots simply become its own folder; every other `name-<id>` folder is
  either a person's explicit folder or in nobody's roots (so owner() is None).
* `people_root` is an editable setting (page) with an env default (`PEOPLE_ROOT`, installer remembers it).
* No full ids anywhere in the UI/API errors/log text (last 4 digits only); the folder name is the option value only.
* Files directly in a `name-<id>` folder get no folder album (it would put the id into Immich).
