"""Runs one import pipeline per person (own Immich key, own records, own queue) and routes files to them.

The main account's pipeline is created by `__main__` exactly as before (state.db, env key); everyone else is
created from users.json and can be added, changed and removed while the bridge runs.
"""

from __future__ import annotations

import collections
import logging
import os
import shutil
import threading
import time
from dataclasses import dataclass
from typing import Callable

from bridge.config import Config
from bridge.people import PeopleLayout, last4, parse_folder
from bridge.immich import ALBUM_PERMISSION_WHY, ALBUM_PERMISSIONS, REQUIRED_PERMISSIONS, ImmichClient
from bridge.router import Router
from bridge.scanner import is_within_dirs, iter_candidates
from bridge.state import StateStore
from bridge.userview import UserView
from bridge.users import MAIN_ID, User, UsersError, UsersStore
from bridge.worker import ImportWorker

log = logging.getLogger("bridge.manager")


CHECKING = "checking which Immich account this key belongs to"


@dataclass
class Runtime:
    uid: str
    worker: ImportWorker
    state: StateStore
    client: ImmichClient
    view: UserView
    seq: int = 0


class UserManager:
    def __init__(
        self,
        cfg: Config,
        users: UsersStore,
        router: Router,
        allowed: set[str],
        client_factory: Callable[[str], ImmichClient] | None = None,
    ):
        self.cfg = cfg
        self.users = users
        self.router = router
        self._allowed = allowed
        self._client_factory = client_factory or (
            lambda key: ImmichClient(
                cfg.immich_url, key, cfg.device_id, verify_tls=cfg.verify_tls, upload_timeout=cfg.upload_timeout
            )
        )
        # Folder-per-person mode (cfg.people_root): which folder is whose, proven by the Immich id in its name
        self.people = PeopleLayout(lambda: cfg.people_root, self._main_id, lambda: cfg.watch_dirs, lambda: cfg.browse_roots)
        self.wake: Callable[[], None] | None = None  # asks the sweep to run (set by __main__)
        self._rt: dict[str, Runtime] = {}
        self._seq = 0
        # Guards the runtime table and routing decisions ONLY. Never held across a network call or a thread join.
        self._lock = threading.RLock()
        # files the hook reported that sit in nobody's folder (shown on the Users tab so they are not silent)
        self.unassigned_count = 0
        self.unassigned_recent: collections.deque[dict] = collections.deque(maxlen=20)
        self._unassigned_seen: set[str] = set()

    def _main_id(self) -> str:
        """The Immich account id of the main key: confirmed by Immich, else the one remembered from the last run."""
        rt = self._rt.get(MAIN_ID)
        if rt is None:
            return ""
        # LIVE answer only. The id remembered from an earlier run must never route files: the key may belong to a
        # different account now, and then the old account's folder would be uploaded with the new key.
        return (rt.worker.immich_user or {}).get("id") or ""

    # -- lifecycle -----------------------------------------------------------------------

    def _users_dir(self) -> str:
        return os.path.join(os.path.dirname(self.cfg.state_db) or ".", "users")

    def _state_path(self, uid: str) -> str:
        return os.path.join(self._users_dir(), uid, "state.db")

    def start_main(self, state: StateStore, client: ImmichClient) -> Runtime:
        view = UserView(self.cfg, MAIN_ID, self.users)
        view.main_dirs = self.people.main_dirs
        view.people_enabled = lambda: self.people.enabled
        worker = ImportWorker(view, state, client, self._allowed, router=self.router, user_id=MAIN_ID)
        rt = Runtime(MAIN_ID, worker, state, client, view)
        with self._lock:
            self._seq += 1
            rt.seq = self._seq
            self._rt[MAIN_ID] = rt
        worker.start()
        return rt

    def start_user(self, user: User) -> Runtime | None:
        if not user.enabled:
            return None
        directory = os.path.join(self._users_dir(), user.id)
        os.makedirs(directory, mode=0o700, exist_ok=True)
        try:
            os.chmod(self._users_dir(), 0o700)
            os.chmod(directory, 0o700)
        except OSError:
            pass
        state = StateStore(self._state_path(user.id))
        client = self._client_factory(user.api_key)
        view = UserView(self.cfg, user.id, self.users)
        # held until Immich has said which account this key is (so two people can never share one by accident)
        view.blocked = CHECKING
        worker = ImportWorker(view, state, client, self._allowed, router=self.router, user_id=user.id)
        rt = Runtime(user.id, worker, state, client, view)
        with self._lock:
            self._seq += 1
            rt.seq = self._seq
            self._rt[user.id] = rt
        worker.start()
        return rt

    def start_all(self) -> None:
        for user in self.users.users():
            try:
                self.start_user(user)
            except Exception:
                # e.g. an unwritable /data/users/<id> or a damaged state.db: that person stays off (shown as not
                # running on the People tab); everybody else keeps importing
                log.exception("could not start user %s - they will not import until this is fixed", user.id)

    def stop_all(self) -> None:
        for rt in self.runtimes():
            rt.worker.stop()

    def close_all(self) -> None:
        """Orderly shutdown: stop every worker, wait for uploads in flight, then close the people's stores."""
        runtimes = self.runtimes()
        for rt in runtimes:
            rt.worker.stop()
        for rt in runtimes:
            if not rt.worker.join(20):
                log.warning("user %s: an upload was still running at shutdown", rt.uid)
            if rt.uid != MAIN_ID:  # main's store/client are closed by __main__
                rt.state.close()
                rt.client.close()

    def runtime(self, uid: str) -> Runtime | None:
        with self._lock:
            return self._rt.get(uid)

    def runtimes(self) -> list[Runtime]:
        with self._lock:
            return list(self._rt.values())

    def check_identities(self) -> None:
        """Asks Immich who each key belongs to (and what it may do), then blocks anyone who shares an account."""
        for rt in self.runtimes():
            self._identify(rt)
        self._flag_duplicates()
        self.people.invalidate()
        if self.wake:
            self.wake()  # main's folder is only known now: look at it right away

    def _identify(self, rt: Runtime) -> None:
        try:
            rt.worker.refresh_identity()
            rt.worker.check_album_permission()
        except Exception:
            log.exception("identity check failed for %s", rt.uid)

    def _flag_duplicates(self) -> None:
        """Two people on ONE Immich account would both import every file into it. The main account always wins;
        the later person is held (not deleted) with a visible reason."""
        seen: dict[str, str] = {}
        runtimes = sorted(self.runtimes(), key=lambda r: (r.uid != MAIN_ID, r.seq))  # the established importer wins
        main_rt = next((r for r in runtimes if r.uid == MAIN_ID), None)
        main_known = bool(main_rt and (main_rt.worker.immich_user or {}).get("id"))
        for rt in runtimes:
            who = (rt.worker.immich_user or {}).get("id")
            user = self.users.get(rt.uid) if rt.uid != MAIN_ID else None
            if user and user.immich_id and who and who.lower() != user.immich_id:
                # the key no longer belongs to the account this person's folder is named for
                rt.view.blocked = f"the API key now belongs to a different Immich account (…{last4(who)}) than this person's folder (…{last4(user.immich_id)})"
                log.error("user %s held: %s", rt.uid, rt.view.blocked)
                continue
            if not who or (rt.uid != MAIN_ID and not main_known):
                # fail closed: until main's account is known nobody can be shown to differ from it
                if rt.uid != MAIN_ID:
                    rt.view.blocked = rt.view.blocked or CHECKING
                continue
            if who in seen:
                rt.view.blocked = f"uses the same Immich account as '{seen[who]}'"
                log.error("user %s %s - held, give them their own Immich account/API key", rt.uid, rt.view.blocked)
            else:
                seen[who] = rt.uid
                rt.view.blocked = None

    # -- routing ---------------------------------------------------------------------------

    def route(self, path: str, login: str | None = None) -> str | None:
        """The person this file goes to (recording a login claim when that decides it), or None."""
        with self._lock:
            owner = self.router.owner(path)
            if owner == MAIN_ID and login:
                target = self.users.all_logins().get(login)
                main_rt = self._rt.get(MAIN_ID)
                already = main_rt.state.get(path) if main_rt else None
                if already is not None and already.status in ("imported", "duplicate"):
                    return owner  # main already imported it: a login does not re-import old files elsewhere
                if target and target != MAIN_ID and self.router.claim(path, target):
                    owner = self.router.owner(path)
            return owner

    def enqueue(self, path: str, source: str, login: str | None = None) -> bool:
        uid = self.route(path, login)
        rt = self.runtime(uid) if uid else None
        if rt is None:
            return False
        return rt.worker.enqueue(path, source)

    def note_unassigned(self, path: str, login: str | None, source: str | None) -> None:
        self.unassigned_count += 1
        if path in self._unassigned_seen:
            return
        if len(self._unassigned_seen) > 1000:
            self._unassigned_seen.clear()
        self._unassigned_seen.add(path)
        self.unassigned_recent.append({"path": path, "login": login or "", "source": source or "", "at": time.time()})
        log.warning("file %s (uploaded by %s) is in nobody's watched folder - not imported", path, login or "an unknown login")

    def sweep_all(self) -> int:
        queued = 0
        if any(rt.worker.immich_user is None for rt in self.runtimes()):
            self.check_identities()  # Immich was unreachable earlier: ask again
        for rt in self.runtimes():
            if rt.view.blocked == CHECKING and rt.worker.immich_user is not None:
                self._flag_duplicates()
                break
        for rt in self.runtimes():
            try:
                queued += rt.worker.sweep()
            except Exception:
                log.exception("sweep failed for %s", rt.uid)
        try:
            self.router.gc()
        except Exception:
            log.exception("claims cleanup failed")
        return queued

    # -- web page data -----------------------------------------------------------------------

    def describe(self, uid: str) -> dict | None:
        rt = self.runtime(uid)
        main = uid == MAIN_ID
        user = None if main else self.users.get(uid)
        if not main and user is None:
            return None
        folders = self.people.main_dirs() if main else user.folders
        who = rt.worker.immich_user if rt else None
        iid = (who or {}).get("id") or ("" if main else user.immich_id)
        return {
            "id": uid,
            "name": self.users.main["name"] if main else user.name,
            "is_main": main,
            "enabled": True if main else user.enabled,
            "paused": bool(self.users.main["paused"]) if main else user.paused,
            "blocked": rt.view.blocked if rt else None,
            "running": rt is not None,
            "folders": list(folders),
            "missing_folders": [f for f in folders if not os.path.isdir(f)],
            "priority_dirs": [] if (main and self.people.enabled) else list(self.cfg.priority_dirs if main else user.priority_dirs),
            "folder_waiting": bool(main and self.people.enabled and not folders),
            "id_last4": last4(iid),
            "cp_logins": list(self.users.main["cp_logins"] if main else user.cp_logins),
            "album_name": self.cfg.album_name if main else user.album_name,
            "album_from_folder": self.cfg.album_from_folder if main else user.album_from_folder,
            "api_key_set": bool(self.cfg.api_key) if main else bool(user.api_key),
            "immich_user": who,
            "identity_ok": who is not None if rt else None,
            "queue": rt.worker.queue_size if rt else 0,
            "counts": rt.state.counts() if rt else {},
            "last_error": rt.state.last_failure() if rt else None,
            "album_permission": rt.worker.album_permission if rt else None,
            "account_change": rt.worker.account_change if rt else None,
        }

    def describe_all(self) -> dict:
        people = [self.describe(MAIN_ID)] + [self.describe(u.id) for u in self.users.users()]
        return {
            "users": people,
            "people_root": self.people.root(),
            "people_mode": self.people.mode(),
            "people_folders": self.people_folders(),
            "ignored_dirs": list(self.users.ignored_dirs),
            "unassigned": {"count": self.unassigned_count, "recent": list(self.unassigned_recent)},
        }

    # -- changes ------------------------------------------------------------------------------

    def _probe(self, api_key: str) -> dict:
        """Asks Immich who this key is and what it may do. Raises UsersError naming EXACTLY what is wrong: an invalid
        key, Immich unreachable, or the list of permissions the key lacks."""
        client = self._client_factory(api_key)
        try:
            granted, why = client.key_permissions()
            if granted is None:
                log.warning("key check failed: %s", why)
                raise UsersError(why or "Immich did not say what that key may do")
            has_all = "all" in granted
            missing = [] if has_all else [p for p in REQUIRED_PERMISSIONS if p not in granted]
            if missing:
                have = ", ".join(sorted(granted)) or "no permissions at all"
                lines = "; ".join(f"{p} (needed {REQUIRED_PERMISSIONS[p]})" for p in missing)
                log.warning("key check failed: key lacks %s; it has: %s", ", ".join(missing), have)
                raise UsersError(
                    f"That Immich API key is missing required permission{'s' if len(missing) > 1 else ''}: {lines}. "
                    f"It currently has: {have}. In Immich (Account Settings > API Keys) create a new key with all "
                    "permissions, or at least the ones listed above plus album.read, album.create and albumAsset.create."
                )
            who, why = client.whoami_ex()
            if who is None or not who.get("id"):
                log.warning("key check failed: %s", why or "Immich gave no account id")
                raise UsersError(why or "Immich did not say whose account that key is")
            album_missing = [] if has_all else [p for p in ALBUM_PERMISSIONS if p not in granted]
            albums = {"ok": not album_missing, "missing": album_missing,
                      "why": {p: ALBUM_PERMISSION_WHY[p] for p in album_missing}}
            return {"who": who, "albums": albums, "permissions": sorted(granted)}
        finally:
            client.close()

    def check_key(self, api_key: str, ignore_uid: str | None = None) -> dict:
        """Probes Immich (network, so callers must NOT hold the lock) and refuses an account someone already uses."""
        info = self._probe(api_key)
        self._refuse_shared_account(info, ignore_uid)
        return info

    def _refuse_shared_account(self, info: dict, ignore_uid: str | None) -> None:
        for rt in self.runtimes():
            other = (rt.worker.immich_user or {}).get("id")
            if other and other == info["who"]["id"] and rt.uid != ignore_uid:
                name = self.describe(rt.uid)["name"]
                raise UsersError(f"That API key belongs to the same Immich account as {name}; each person needs their own account")

    def _check_people_folders(self, folders: list[str], identity: str, name: str) -> None:
        """Inside the people folder a person may only have a folder named for THEIR Immich account (and never main's)."""
        if not self.people.enabled or not identity:
            return
        root = os.path.realpath(self.people.root())
        main_id = self._main_id().lower()
        for f in folders:
            real = os.path.realpath(f)
            if not is_within_dirs(real, [root]) or real == root:
                continue
            top = os.path.relpath(real, root).split(os.sep)[0]
            parsed = parse_folder(top)
            if parsed is None or parsed[1] != identity.lower():
                raise UsersError(f"{f} is inside the people folder, so it must be named <firstname>-<{name}'s Immich id>; it is not")
            if main_id and parsed[1] == main_id:
                raise UsersError(f"{f} is the main account's folder")

    def people_folders(self) -> dict:
        """What the Add person dropdown shows: folders under the people root, who has them, never the full id."""
        if not self.people.enabled:
            return {"enabled": False, "mode": self.people.mode(), "root": "", "folders": [], "skipped": []}
        entries, skipped = self.people.scan(force=True)
        main_id = self._main_id().lower()
        taken = {(u.immich_id or "").lower(): u.id for u in self.users.users() if u.immich_id}
        by_path = {f: u.id for u in self.users.users() for f in u.folders}
        names: dict[str, int] = {}
        for e in entries:
            names[e["name"].lower()] = names.get(e["name"].lower(), 0) + 1
        out = []
        for e in entries:
            claimed = MAIN_ID if (main_id and e["id"] == main_id) else taken.get(e["id"]) or by_path.get(e["path"])
            out.append({"folder": e["folder"], "name": e["name"], "claimed_by": claimed,
                        "last4": last4(e["id"]), "duplicate_name": names[e["name"].lower()] > 1})
        return {"enabled": True, "mode": self.people.mode(), "root": self.people.root(), "folders": out, "skipped": skipped}

    def _folder_for_key(self, folder: str, info: dict) -> dict:
        """The detected folder entry, if this key's account is the one whose id is in the folder's name."""
        entry = next((e for e in self.people.scan(force=True)[0] if e["folder"] == folder), None)
        if entry is None:
            raise UsersError("That folder was not found any more. Press refresh and pick it again.")
        key_id = (info["who"].get("id") or "").lower()
        if key_id != entry["id"]:
            who = info["who"]
            raise UsersError(
                f"That API key belongs to {who.get('name') or '?'} ({who.get('email') or '?'}), whose account id ends "
                f"…{last4(key_id)}, but the folder for {entry['name']} is for the account ending …{last4(entry['id'])}. "
                f"Use {entry['name']}'s own API key (created while logged in to Immich as {entry['name']}), or pick the "
                "folder that belongs to this key.")
        return entry

    def check_person_key(self, folder: str, api_key: str) -> dict:
        info = self.check_key(api_key.strip())
        self._folder_for_key(folder, info)
        info["folder_ok"] = True
        return info

    def add_person_from_folder(self, data: dict) -> dict:
        folder, key = data.get("people_folder"), data.get("api_key")
        if not isinstance(folder, str) or not isinstance(key, str) or not key.strip():
            raise UsersError("pick a person and paste their API key")
        if not self.people.enabled:
            raise UsersError("no folders named <firstname>-<immich id> were found (create them in copyparty, then refresh)")
        info = self.check_key(key.strip())
        entry = self._folder_for_key(folder, info)
        for e in self.people_folders()["folders"]:
            if e["folder"] == folder and e["claimed_by"]:
                raise UsersError(f"{entry['name']} is already set up")
        return self.add_user({"name": entry["name"], "api_key": key.strip(), "folders": [entry["path"]],
                              "immich_id": entry["id"]}, info=info)

    def add_user(self, data: dict, info: dict | None = None) -> dict:
        key = data.get("api_key")
        if not isinstance(key, str) or not key.strip():
            raise UsersError("api_key is required")
        if info is None:
            info = self.check_key(key.strip())  # network: outside the lock
        with self._lock:
            self._refuse_shared_account(info, None)  # re-check: somebody may have been added meanwhile
            if isinstance(data.get("folders"), list):
                self._check_people_folders([f for f in data["folders"] if isinstance(f, str)], info["who"].get("id") or "", str(data.get("name") or "this person"))
            user = self.users.add(data)  # starts paused: review, then press Review & start
            try:
                rt = self.start_user(user)
                if rt is not None:
                    rt.worker.immich_user = info["who"]
                    rt.worker._track_account(info["who"])
                    rt.worker.album_permission = info["albums"]
                    self._flag_duplicates()
            except Exception:
                self.users.remove(user.id, ignore_folders=False)
                self._rt.pop(user.id, None)
                raise
        log.info("added user %s (Immich account %s <%s>), paused until reviewed", user.id, info["who"]["name"], info["who"]["email"])
        return self.describe(user.id)

    def update_user(self, uid: str, data: dict) -> dict:
        if not isinstance(uid, str):
            raise UsersError("no such user", 404)
        if uid == MAIN_ID:
            allowed = {k: v for k, v in data.items() if k in ("name", "cp_logins", "paused")}
            if set(data) - set(allowed):
                raise UsersError("the main account's folders and settings are on the Folders & settings tab")
            self.users.update_main(allowed)
            return self.describe(MAIN_ID)
        key = data.get("api_key")
        info = None
        if isinstance(key, str) and key.strip():
            info = self.check_key(key.strip(), ignore_uid=uid)  # network: outside the lock
        else:
            data = {k: v for k, v in data.items() if k != "api_key"}
        stale = None
        with self._lock:
            old = self.users.get(uid)
            if old is None:
                raise UsersError("no such user", 404)
            if info is not None:
                self._refuse_shared_account(info, uid)
                if old.immich_id and (info["who"].get("id") or "").lower() != old.immich_id:
                    raise UsersError(
                        f"That key belongs to a different Immich account (…{last4(info['who'].get('id') or '')}) than "
                        f"{old.name}'s folder is for (…{last4(old.immich_id)}). Use {old.name}'s own API key.")
            if isinstance(data.get("folders"), list):
                ident = old.immich_id or ((self.runtime(uid).worker.immich_user or {}).get("id") if self.runtime(uid) else "") or ""
                self._check_people_folders([f for f in data["folders"] if isinstance(f, str)], ident, old.name)
            was_enabled, was_paused = old.enabled, old.paused
            if data.get("paused") is False and was_paused:
                # Resume must not skip the review: files already imported by someone else would be duplicated
                pending = self.adopt_preview(uid)["expected_count"]
                if pending:
                    raise UsersError(
                        f"{pending} file(s) in this person's folders were already imported by somebody else: "
                        "use Review & start so they are handled on purpose", 409)
            folders_changed = "folders" in data and sorted(data["folders"] if isinstance(data["folders"], list) else []) != sorted(old.folders)
            user = self.users.update(uid, data)
            if folders_changed and "paused" not in data:
                self.users.update(uid, {"paused": True})  # a changed folder list needs a fresh look before importing
                log.warning("user %s: folders changed - paused until you press Review & start", uid)
            rt = self.runtime(uid)
            if info is not None and rt is not None:
                # a new key may be another Immich account: install the new client first, then retire the old one
                new_client = self._client_factory(user.api_key)
                old_client, rt.client = rt.client, new_client
                rt.worker._client = new_client
                rt.worker.immich_user = info["who"]
                rt.worker._track_account(info["who"])
                rt.worker.album_permission = info["albums"]
                stale = old_client
            if info is not None:
                self._flag_duplicates()
            if user.enabled and not was_enabled:
                self.start_user(user)
            to_stop = uid if (not user.enabled and rt is not None) else None
        if stale is not None:
            threading.Timer(60.0, stale.close).start()  # in-flight calls on the old client drain first
        if to_stop:
            self._stop_runtime(to_stop)
        if user.enabled and not was_enabled:
            self.check_identities()
        return self.describe(uid)

    def _stop_runtime(self, uid: str) -> None:
        """Stops a person's worker and closes their store - never while a file is still uploading (the close is
        deferred until the worker has actually finished). Call WITHOUT holding the lock."""
        with self._lock:
            rt = self._rt.pop(uid, None)
        if rt is None:
            return
        rt.worker.stop()
        if rt.worker.join(30):
            rt.state.close()
            rt.client.close()
            return
        log.warning("user %s: a file was still uploading when they were stopped; it may already be in Immich", uid)

        def finish() -> None:
            rt.worker.join(3600)
            rt.state.close()
            rt.client.close()

        threading.Thread(target=finish, name=f"close-{uid}", daemon=True).start()

    def remove_user(self, uid: str, confirm_id: str) -> dict:
        if uid == MAIN_ID:
            raise UsersError("the main account cannot be removed")
        if confirm_id != uid:
            raise UsersError(f"type the user id ('{uid}') to confirm")
        with self._lock:
            if self.users.get(uid) is None:
                raise UsersError("no such user", 404)
            self.users.remove(uid)  # their folders go on the ignore list
            # Their login claims are KEPT on purpose: a claimed file in the shared area stays held (owner() returns
            # nobody for a claim whose person is gone) instead of falling into the main account.
        self._stop_runtime(uid)  # joins: outside the lock
        directory = os.path.join(self._users_dir(), uid)
        if is_within_dirs(os.path.realpath(directory), [os.path.realpath(self._users_dir())]) and os.path.isdir(directory):
            shutil.rmtree(directory, ignore_errors=True)
        log.warning("removed user %s; their folders are now ignored (nothing was deleted in Immich or on disk)", uid)
        return {"removed": uid, "ignored_dirs": list(self.users.ignored_dirs)}

    def ignored_preview(self, folder: str) -> dict:
        if folder not in self.users.ignored_dirs:
            raise UsersError("that folder is not on the ignore list", 404)
        files = sum(1 for _ in iter_candidates([folder], self._allowed, 0, {self.cfg.move_subdir}))
        return {"folder": folder, "files": files, "expected_count": files}

    def unignore(self, folder: str, expected_count: int) -> None:
        """Gives a removed person's folder back to the main account (it will import every file in it)."""
        if self.ignored_preview(folder)["expected_count"] != expected_count:
            raise UsersError("the number of files changed; look at the preview again", 409)
        self.users.unignore(folder)

    # -- adopt: give a person the files in their folders ----------------------------------------------

    def adopt_preview(self, uid: str) -> dict:
        user = self.users.get(uid)
        if user is None:
            raise UsersError("no such user", 404)
        others = [rt for rt in self.runtimes() if rt.uid != uid]
        records = sum(rt.state.count_done_under(user.folders) for rt in others)
        claims = self.router.count_claims_under(user.folders)
        files = sum(1 for _ in iter_candidates(user.folders, self._allowed, 0, {self.cfg.move_subdir}))
        return {"files_in_folders": files, "records_to_move": records, "claims_to_drop": claims,
                "expected_count": records + claims}

    def adopt(self, uid: str, expected_count: int) -> dict:
        """Hands the files in this person's folders to them: the previous owner's 'already imported' records for
        those paths are forgotten (their Immich copies stay), claims are dropped, and the person is un-paused so
        the next scan imports the files into THEIR account."""
        with self._lock:
            preview = self.adopt_preview(uid)
            if expected_count != preview["expected_count"]:
                raise UsersError(
                    f"the numbers changed (now {preview['expected_count']}); look at the preview again", 409
                )
            user = self.users.get(uid)
            moved = 0
            for rt in self.runtimes():
                if rt.uid != uid:
                    moved += rt.state.forget_under(user.folders)
            dropped = self.router.drop_under(user.folders)
            self.users.update(uid, {"paused": False})
            log.warning("adopted %s's folders: %d record(s) moved, %d claim(s) dropped", uid, moved, dropped)
            return {"moved": moved, "claims_dropped": dropped, **self.describe(uid)}
