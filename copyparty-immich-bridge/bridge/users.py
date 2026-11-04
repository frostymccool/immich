"""The people the bridge imports for: one Immich account each, plus where their files live.

The original single account ("main") keeps being configured by the environment (IMMICH_API_KEY, WATCH_DIRS,
...) and the settings page. Everyone else lives in `users.json` on the state volume, written atomically with
mode 0600 because it holds their Immich API keys (plaintext at rest, like the installer's env file). API keys
are write-only: nothing in here ever hands one back to the web page.
"""

from __future__ import annotations

import json
import os
import re
import threading
from dataclasses import dataclass, field
from typing import Any

from bridge.scanner import is_within_dirs

MAIN_ID = "main"
RESERVED_IDS = {MAIN_ID, "default", "all", "everyone", "new", "check"}
_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")
_LOGIN_RE = re.compile(r"^[A-Za-z0-9._@+-]{1,64}$")
FILE_VERSION = 1


class UsersError(Exception):
    """Bad input (problems = human-readable list) or an unreadable users file."""

    def __init__(self, problems: list[str] | str, code: int = 400):
        self.problems = [problems] if isinstance(problems, str) else list(problems)
        self.code = code
        super().__init__("; ".join(self.problems))


@dataclass
class User:
    id: str
    name: str
    api_key: str
    folders: list[str]
    priority_dirs: list[str] = field(default_factory=list)
    cp_logins: list[str] = field(default_factory=list)
    album_name: str = ""
    album_from_folder: bool = True
    paused: bool = False
    enabled: bool = True

    def to_dict(self) -> dict[str, Any]:
        return dict(self.__dict__)


def slugify(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:32].strip("-")
    return slug or "user"


def _norm_dir(raw: Any) -> str | None:
    if not isinstance(raw, str) or not raw.strip().startswith("/"):
        return None
    return os.path.normpath(raw.strip())


class UsersStore:
    def __init__(self, path: str, browse_roots: list[str] | None = None):
        self._path = path
        self._browse_roots = browse_roots or []
        self._lock = threading.RLock()
        self.main: dict[str, Any] = {"name": "Main", "cp_logins": [], "paused": False}
        self._users: list[User] = []
        self.ignored_dirs: list[str] = []
        self.version = 0  # bumped on every change (the router rebuilds its folder map when it moves)

    # -- load / save -------------------------------------------------------------

    def load(self) -> None:
        """Reads users.json. A missing file is a single-user install; an unreadable one is an ERROR (never
        silently treated as 'no users', or every user's files would fall into the main account)."""
        with self._lock:
            try:
                with open(self._path, encoding="utf-8") as fh:
                    raw = json.load(fh)
            except FileNotFoundError:
                return
            except (OSError, ValueError) as ex:
                raise UsersError(f"cannot read {self._path}: {ex}. Fix or remove that file and restart.") from ex
            if not isinstance(raw, dict) or raw.get("version") != FILE_VERSION:
                raise UsersError(f"{self._path} has an unknown format (version {raw.get('version') if isinstance(raw, dict) else '?'})")
            try:
                main = raw.get("main") or {}
                self.main = {
                    "name": str(main.get("name") or "Main")[:60],
                    "cp_logins": [str(x) for x in main.get("cp_logins") or []],
                    "paused": bool(main.get("paused", False)),
                }
                self._users = [
                    User(
                        id=str(u["id"]),
                        name=str(u["name"]),
                        api_key=str(u["api_key"]),
                        folders=[str(x) for x in u["folders"]],
                        priority_dirs=[str(x) for x in u.get("priority_dirs") or []],
                        cp_logins=[str(x) for x in u.get("cp_logins") or []],
                        album_name=str(u.get("album_name") or ""),
                        album_from_folder=bool(u.get("album_from_folder", True)),
                        paused=bool(u.get("paused", False)),
                        enabled=bool(u.get("enabled", True)),
                    )
                    for u in raw.get("users") or []
                ]
                self.ignored_dirs = [str(x) for x in raw.get("ignored_dirs") or []]
            except (KeyError, TypeError, ValueError) as ex:
                raise UsersError(f"{self._path} is damaged ({ex!r}). Fix or remove that file and restart.") from ex
            ids = [u.id for u in self._users]
            bad = [i for i in ids if not _ID_RE.match(i) or i in RESERVED_IDS]
            if bad or len(set(ids)) != len(ids):
                raise UsersError(f"{self._path} has invalid or duplicate user ids: {bad or ids}")
            self.version += 1

    def _save(self) -> None:
        body = {
            "version": FILE_VERSION,
            "main": self.main,
            "users": [u.to_dict() for u in self._users],
            "ignored_dirs": self.ignored_dirs,
        }
        directory = os.path.dirname(self._path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        tmp = self._path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)  # never world-readable, not even briefly
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(body, fh, indent=2)
                fh.flush()
                os.fsync(fh.fileno())
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        os.replace(tmp, self._path)
        self.version += 1

    # -- reads ---------------------------------------------------------------------

    def users(self) -> list[User]:
        with self._lock:
            return list(self._users)

    def get(self, uid: str) -> User | None:
        with self._lock:
            return next((u for u in self._users if u.id == uid), None)

    def all_logins(self, exclude: str | None = None) -> dict[str, str]:
        """copyparty login -> user id, for every user including main."""
        with self._lock:
            out = {lg: MAIN_ID for lg in self.main["cp_logins"]} if exclude != MAIN_ID else {}
            for u in self._users:
                if u.id != exclude:
                    out.update({lg: u.id for lg in u.cp_logins})
            return out

    # -- validation -----------------------------------------------------------------

    def _clean_dirs(self, value: Any, label: str, problems: list[str], must_exist: bool) -> list[str]:
        if isinstance(value, str):
            value = value.replace(",", "\n").splitlines()
        if not isinstance(value, list):
            problems.append(f"{label} must be a list of folder paths")
            return []
        out: list[str] = []
        for item in value:
            if isinstance(item, str) and not item.strip():
                continue
            norm = _norm_dir(item)
            if norm is None:
                problems.append(f"{label}: {item!r} is not an absolute path")
            elif norm == "/":
                problems.append(f"{label}: '/' is not allowed")
            elif self._browse_roots and not is_within_dirs(norm, self._browse_roots):
                problems.append(f"{label}: {norm} is outside the folders this container can see")
            elif must_exist and not os.path.isdir(norm):
                problems.append(f"{label}: {norm} does not exist in the container (is it mounted?)")
            elif norm not in out:
                out.append(norm)
        return out

    def _clean_logins(self, value: Any, problems: list[str], mine: str | None) -> list[str]:
        if isinstance(value, str):
            value = value.replace(",", "\n").splitlines()
        if not isinstance(value, list):
            problems.append("cp_logins must be a list of copyparty login names")
            return []
        taken = self.all_logins(exclude=mine)
        out: list[str] = []
        for item in value:
            if isinstance(item, str) and not item.strip():
                continue
            login = item.strip() if isinstance(item, str) else ""
            if not _LOGIN_RE.match(login) or login == "*":
                problems.append(f"copyparty login {item!r} is not valid")
            elif login in taken:
                other = "the main account" if taken[login] == MAIN_ID else f"user '{taken[login]}'"
                problems.append(f"copyparty login '{login}' already belongs to {other}")
            elif login not in out:
                out.append(login)
        return out

    def _validate(self, data: dict[str, Any], current: User | None) -> dict[str, Any]:
        problems: list[str] = []
        out: dict[str, Any] = {}
        allowed = {"name", "api_key", "folders", "priority_dirs", "cp_logins", "album_name", "album_from_folder", "paused", "enabled"}
        unknown = sorted(set(data) - allowed - {"id"})
        if unknown:
            problems.append(f"unknown field(s): {', '.join(unknown)}")
        if "name" in data or current is None:
            name = " ".join(str(data.get("name") or "").split())
            if not name or len(name) > 60 or any(ord(c) < 32 for c in name):
                problems.append("name is required (1-60 characters)")
            out["name"] = name
        key = data.get("api_key")
        if key is not None and key != "":
            if not isinstance(key, str) or not 8 <= len(key.strip()) <= 512 or re.search(r"\s", key.strip()):
                problems.append("api_key does not look like an Immich API key")
            else:
                out["api_key"] = key.strip()
        elif current is None:
            problems.append("api_key is required")
        if "folders" in data or current is None:
            folders = self._clean_dirs(data.get("folders", []), "folders", problems, must_exist=True)
            if not folders and not problems:
                problems.append("at least one folder is required")
            out["folders"] = folders
        if "priority_dirs" in data:
            out["priority_dirs"] = self._clean_dirs(data["priority_dirs"], "priority_dirs", problems, must_exist=False)
        if "cp_logins" in data:
            out["cp_logins"] = self._clean_logins(data["cp_logins"], problems, current.id if current else None)
        if "album_name" in data:
            if not isinstance(data["album_name"], str) or len(data["album_name"]) > 200:
                problems.append("album_name must be text of at most 200 characters")
            else:
                out["album_name"] = " ".join(data["album_name"].split())
        for flag in ("album_from_folder", "paused", "enabled"):
            if flag in data:
                if not isinstance(data[flag], bool):
                    problems.append(f"{flag} must be true or false")
                else:
                    out[flag] = data[flag]
        if problems:
            raise UsersError(problems)
        return out

    def _check_layout(self, folders: list[str], priority: list[str], mine: str | None) -> None:
        """Folders of different people may not be equal or nested (they would fight over files); priority dirs
        must sit inside the person's own folders. Everything may sit inside main's (catch-all) folders."""
        problems: list[str] = []
        for other in self._users:
            if other.id == mine:
                continue
            for f in folders:
                for g in other.folders:
                    if is_within_dirs(f, [g]) or is_within_dirs(g, [f]):
                        problems.append(f"{f} overlaps {g}, which belongs to {other.name}")
        for p in priority:
            if not is_within_dirs(p, folders):
                problems.append(f"priority folder {p} must be inside one of this person's folders")
        if problems:
            raise UsersError(problems)

    # -- changes -----------------------------------------------------------------------

    def add(self, data: dict[str, Any]) -> User:
        with self._lock:
            clean = self._validate(data, None)
            self._check_layout(clean["folders"], clean.get("priority_dirs", []), None)
            base = slugify(clean["name"])
            taken = {u.id for u in self._users} | RESERVED_IDS
            uid, n = base, 2
            while uid in taken:
                uid, n = f"{base[:28]}-{n}", n + 1
            user = User(id=uid, **{**{"priority_dirs": [], "cp_logins": [], "album_name": "", "album_from_folder": True,
                                      "paused": True, "enabled": True}, **clean})
            self._users.append(user)
            ignored_before = list(self.ignored_dirs)
            self._release_ignored(user.folders)
            try:
                self._save()
            except OSError as ex:
                self._users.remove(user)
                self.ignored_dirs = ignored_before
                raise UsersError(f"could not save users: {ex}", 500) from ex
            return user

    def update(self, uid: str, data: dict[str, Any]) -> User:
        with self._lock:
            user = self.get(uid)
            if user is None:
                raise UsersError("no such user", 404)
            clean = self._validate(data, user)
            before = dict(user.__dict__)
            folders = clean.get("folders", user.folders)
            priority = clean.get("priority_dirs", user.priority_dirs)
            if "folders" in clean or "priority_dirs" in clean:
                self._check_layout(folders, priority, uid)
            for k, v in clean.items():
                setattr(user, k, v)
            ignored_before = list(self.ignored_dirs)
            # a folder taken away from a person must not quietly fall into the main account
            for f in before["folders"]:
                if not is_within_dirs(f, user.folders) and f not in self.ignored_dirs:
                    self.ignored_dirs.append(f)
            self._release_ignored(user.folders)
            try:
                self._save()
            except OSError as ex:
                user.__dict__.update(before)
                self.ignored_dirs = ignored_before
                raise UsersError(f"could not save users: {ex}", 500) from ex
            return user

    def _release_ignored(self, folders: list[str]) -> None:
        """A folder given to a (new) person is no longer 'ignored'."""
        self.ignored_dirs = [d for d in self.ignored_dirs if not is_within_dirs(d, folders)]

    def update_main(self, data: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            problems: list[str] = []
            new = dict(self.main)
            if "name" in data:
                name = " ".join(str(data["name"] or "").split())
                if not name or len(name) > 60:
                    problems.append("name is required (1-60 characters)")
                new["name"] = name
            if "cp_logins" in data:
                new["cp_logins"] = self._clean_logins(data["cp_logins"], problems, MAIN_ID)
            if "paused" in data:
                if not isinstance(data["paused"], bool):
                    problems.append("paused must be true or false")
                else:
                    new["paused"] = data["paused"]
            if problems:
                raise UsersError(problems)
            old, self.main = self.main, new
            try:
                self._save()
            except OSError as ex:
                self.main = old
                raise UsersError(f"could not save users: {ex}", 500) from ex
            return self.main

    def remove(self, uid: str, ignore_folders: bool = True) -> User:
        """Removes a user. Their folders go on the ignore list, so their files do NOT quietly fall into the
        main account (which watches the folder above)."""
        with self._lock:
            user = self.get(uid)
            if user is None:
                raise UsersError("no such user", 404)
            self._users.remove(user)
            before = list(self.ignored_dirs)
            if ignore_folders:
                for f in user.folders:
                    if f not in self.ignored_dirs:
                        self.ignored_dirs.append(f)
            try:
                self._save()
            except OSError as ex:
                self._users.append(user)
                self.ignored_dirs = before
                raise UsersError(f"could not save users: {ex}", 500) from ex
            return user

    def unignore(self, folder: str) -> None:
        with self._lock:
            norm = _norm_dir(folder)
            if norm is None or norm not in self.ignored_dirs:
                raise UsersError("that folder is not on the ignore list", 404)
            self.ignored_dirs.remove(norm)
            self._save()
