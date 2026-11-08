"""Folder-per-person layout: one folder under a "people root", named `<firstname>-<immich user id>`.

The folder name itself says whose it is, and the bridge proves it: the API key a person is added with must belong to
the Immich account whose full id is in the folder name. Folders whose id matches nobody are imported by NOBODY.
"""

from __future__ import annotations

import os
import re
import threading
import time
from typing import Callable

from bridge.scanner import is_within_dirs

_UUID = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
FOLDER_RE = re.compile(rf"^(?P<name>.+?)-(?P<id>{_UUID})$")


def parse_folder(name: str) -> tuple[str, str] | None:
    """`leza-3f2a9c1e-7b4d-4e0a-9d21-1c8e5a6b5567` -> ('Leza', '3f2a9c1e-...'); None when it does not look like that."""
    m = FOLDER_RE.match(name)
    if not m or name.startswith("."):
        return None
    first = " ".join(m.group("name").split())
    if not first:
        return None
    return first[:1].upper() + first[1:], m.group("id").lower()


def last4(uid: str) -> str:
    return uid[-4:] if uid else ""


class PeopleLayout:
    """Scans the people root (cached for a few seconds: the router asks for it once per file) and says which folder
    belongs to which Immich account."""

    TTL = 3.0

    def __init__(
        self,
        get_root: Callable[[], str],
        main_id: Callable[[], str],
        fallback_main_dirs: Callable[[], list[str]],
        get_browse_roots: Callable[[], list[str]] | None = None,
    ):
        self._get_root = get_root
        self._browse_roots = get_browse_roots or (lambda: [])
        self._auto_cache: tuple[float, str] | None = None
        self._main_id = main_id
        self._fallback = fallback_main_dirs
        self._lock = threading.Lock()
        self._cache: tuple[str, float, list[dict], list[str]] | None = None

    def mode(self) -> str:
        """'off' (switched off), 'set' (an explicit folder), or 'auto' (the mounted data folder is searched)."""
        raw = (self._get_root() or "").strip()
        if raw.lower() == "off":
            return "off"
        return "set" if raw else "auto"

    def root(self) -> str:
        """The people root, or '' when folder-per-person mode is off / nothing to detect.
        Auto: the first mounted data folder that directly contains at least one `firstname-<uuid>` folder."""
        raw = (self._get_root() or "").strip()
        if raw.lower() == "off":
            return ""
        if raw:
            return os.path.normpath(raw)
        now = time.time()
        with self._lock:
            c = self._auto_cache
            if c and now - c[0] < self.TTL:
                return c[1]
        found = ""
        for r in self._browse_roots():
            try:
                if any(parse_folder(n) and os.path.isdir(os.path.join(r, n)) for n in os.listdir(r)):
                    found = os.path.normpath(r)
                    break
            except OSError:
                continue
        with self._lock:
            self._auto_cache = (now, found)
        return found

    @property
    def enabled(self) -> bool:
        return bool(self.root())

    def invalidate(self) -> None:
        with self._lock:
            self._cache = None
            self._auto_cache = None

    def scan(self, force: bool = False) -> tuple[list[dict], list[str]]:
        """(entries, skipped): entries = [{folder, name, id, path}] for folders named like `name-<uuid>`;
        skipped = other (non-hidden) folder names that are NOT picked up."""
        root = self.root()
        if not root:
            return [], []
        now = time.time()
        with self._lock:
            c = self._cache
            if c and not force and c[0] == root and now - c[1] < self.TTL:
                return c[2], c[3]
        entries: list[dict] = []
        skipped: list[str] = []
        try:
            names = sorted(os.listdir(root), key=str.lower)
        except OSError:
            names = []
        for n in names:
            if n.startswith("."):
                continue
            path = os.path.join(root, n)
            # a symlink (or anything resolving outside the people root) can never be somebody's folder: it could
            # point at another person's photos while carrying the right id in its name
            if os.path.islink(path) or not os.path.isdir(path):
                if os.path.islink(path):
                    skipped.append(n)
                continue
            if os.path.dirname(os.path.realpath(path)) != os.path.realpath(root):
                skipped.append(n)
                continue
            parsed = parse_folder(n)
            if parsed is None:
                skipped.append(n)
                continue
            entries.append({"folder": n, "name": parsed[0], "id": parsed[1], "path": path})
        with self._lock:
            self._cache = (root, now, entries, skipped)
        return entries, skipped

    def main_dirs(self) -> list[str]:
        """The folders the MAIN account imports from. Folder-per-person mode: only its own `name-<its id>` folder
        (nothing at all until its account id is known, so nothing can land in the wrong account). Off: WATCH_DIRS."""
        if not self.enabled:
            return list(self._fallback())
        mid = (self._main_id() or "").lower()
        if not mid:
            return []
        return [e["path"] for e in self.scan()[0] if e["id"] == mid and is_within_dirs(e["path"], [self.root()])]
