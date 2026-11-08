"""Decides which person a file belongs to. ONE function (`Router.owner`) is used by the sweep, the hook and the
worker, so they can never disagree.

Rules, in order:
  1. Folders are matched by the LONGEST matching folder. The main account's watched folders are the catch-all;
     folders of other people and the 'ignored' list (folders of removed people) are more specific and win.
  2. A hook CLAIM (the uploader's copyparty login maps to a person) may move a file out of the main catch-all
     into that person's account - never out of another person's explicit folder (folder beats login).
  3. With more than one person, symlinks are refused and the file's real location must stay inside the
     owner's real folder, so nobody can plant a link to somebody else's photos.
"""

from __future__ import annotations

import logging
import os
import sqlite3
import threading
from dataclasses import dataclass

from bridge.scanner import is_within_dirs
from bridge.users import MAIN_ID, UsersStore

log = logging.getLogger("bridge.router")


@dataclass(frozen=True)
class _Root:
    path: str
    real: str
    owner: str | None  # None = ignored folder


class Router:
    def __init__(self, main_dirs, users: UsersStore, claims_db: str | None = None, strict=None):
        """`main_dirs` is a callable returning main's CURRENT watched folders (settings can change them)."""
        self._main_dirs = main_dirs
        self._strict = strict  # callable: True = refuse symlinks even with a single person (folder-per-person mode)
        self._users = users
        self._claims_db = claims_db
        self._db: sqlite3.Connection | None = None
        self._db_lock = threading.Lock()
        self._key: tuple | None = None
        self._roots: list[_Root] = []
        self._enabled: set[str] = set()
        self._lock = threading.Lock()

    # -- layout --------------------------------------------------------------------

    @property
    def multi(self) -> bool:
        return bool(self._users.users()) or bool(self._strict and self._strict())

    def _layout(self) -> list[_Root]:
        key = (tuple(self._main_dirs()), self._users.version)
        with self._lock:
            if key != self._key:
                roots: list[_Root] = []
                for d in self._main_dirs():
                    roots.append(_Root(os.path.normpath(d), os.path.realpath(d), MAIN_ID))
                enabled = {MAIN_ID}
                for u in self._users.users():
                    for f in u.folders:
                        roots.append(_Root(os.path.normpath(f), os.path.realpath(f), u.id))
                    if u.enabled:
                        enabled.add(u.id)
                for f in self._users.ignored_dirs:
                    roots.append(_Root(os.path.normpath(f), os.path.realpath(f), None))
                # longest first; at equal length a person beats main, an ignored folder beats everyone
                roots.sort(key=lambda r: (len(r.path), r.owner is None, r.owner != MAIN_ID), reverse=True)
                self._roots, self._enabled, self._key = roots, enabled, key
            return self._roots

    def folders_of(self, uid: str) -> list[str]:
        return [r.path for r in self._layout() if r.owner == uid]

    def other_roots(self, uid: str) -> list[str]:
        """Folders of other people / ignored folders that sit inside this person's folders (pruned from the walk)."""
        mine = self.folders_of(uid)
        return [r.path for r in self._layout() if r.owner != uid and is_within_dirs(r.path, mine)]

    def union(self) -> list[str]:
        return sorted({r.path for r in self._layout() if r.owner is not None})

    # -- ownership ---------------------------------------------------------------------

    def owner(self, path: str) -> str | None:
        """User id that owns `path`, or None (not in any watched folder / ignored / refused)."""
        norm = os.path.normpath(path)
        best: _Root | None = None
        for r in self._layout():
            if is_within_dirs(norm, [r.path]):
                best = r
                break
        if best is None or best.owner is None:
            return None
        if self.multi:
            if os.path.islink(norm):
                return None
            if not is_within_dirs(os.path.realpath(norm), [best.real]):
                return None  # resolves outside the owner's folder (a symlinked directory)
        if best.owner == MAIN_ID:
            claimed = self._claimed_owner(norm)
            if claimed:
                # a claim whose person is disabled/removed HOLDS the file: it must never fall into the main account
                return claimed if claimed in self._enabled else None
        return best.owner

    # -- claims --------------------------------------------------------------------------

    def _conn(self) -> sqlite3.Connection | None:
        if not self._claims_db:
            return None
        if self._db is None:
            directory = os.path.dirname(self._claims_db)
            if directory:
                os.makedirs(directory, exist_ok=True)
            self._db = sqlite3.connect(self._claims_db, check_same_thread=False)
            self._db.execute(
                "CREATE TABLE IF NOT EXISTS claims (path TEXT PRIMARY KEY, user_id TEXT NOT NULL, "
                "size INTEGER NOT NULL, mtime REAL NOT NULL)"
            )
            self._db.commit()
            try:
                os.chmod(self._claims_db, 0o600)
            except OSError:
                pass
        return self._db

    def _claimed_owner(self, norm: str) -> str | None:
        if not self._claims_db or not (os.path.exists(self._claims_db) or self._db):
            return None
        with self._db_lock:
            db = self._conn()
            row = db.execute("SELECT user_id, size, mtime FROM claims WHERE path = ?", (norm,)).fetchone() if db else None
        if not row:
            return None
        try:
            st = os.stat(norm)
        except OSError:
            return None
        if st.st_size != row[1] or abs(st.st_mtime - row[2]) > 1.0:
            return None  # a different file now sits at this path: the old claim no longer applies
        return row[0]

    def claim(self, path: str, uid: str) -> bool:
        """Records that the uploader's login says this file belongs to `uid`. Only for main-owned paths."""
        norm = os.path.normpath(path)
        if self.owner_by_folder(norm) != MAIN_ID or uid == MAIN_ID or uid not in self._enabled:
            return False
        try:
            st = os.stat(norm)
        except OSError:
            return False
        with self._db_lock:
            db = self._conn()
            if db is None:
                return False
            old = db.execute("SELECT user_id, size, mtime FROM claims WHERE path = ?", (norm,)).fetchone()
            if old and old[0] != uid and old[1] == st.st_size and abs(old[2] - st.st_mtime) <= 1.0:
                return False  # an existing claim is never overwritten (first uploader wins)
            db.execute(
                "INSERT INTO claims (path, user_id, size, mtime) VALUES (?, ?, ?, ?) "
                "ON CONFLICT(path) DO UPDATE SET user_id=excluded.user_id, size=excluded.size, mtime=excluded.mtime",
                (norm, uid, st.st_size, st.st_mtime),
            )
            db.commit()
        return True

    def owner_by_folder(self, norm: str) -> str | None:
        for r in self._layout():
            if is_within_dirs(norm, [r.path]):
                return r.owner
        return None

    def claimed_for(self, uid: str) -> list[str]:
        """Paths claimed for `uid` that still exist (the sweep retries them, they are outside its folders)."""
        if not self._claims_db or not (os.path.exists(self._claims_db) or self._db):
            return []
        with self._db_lock:
            db = self._conn()
            rows = db.execute("SELECT path FROM claims WHERE user_id = ?", (uid,)).fetchall() if db else []
        return [p for (p,) in rows if os.path.exists(p)]

    def drop_user(self, uid: str) -> int:
        return self._delete("DELETE FROM claims WHERE user_id = ?", (uid,))

    @staticmethod
    def _under_sql(folder: str) -> tuple[str, tuple]:
        f = os.path.normpath(folder)
        inside = f if f.endswith("/") else f + "/"
        return "(path = ? OR substr(path, 1, ?) = ?)", (f, len(inside), inside)

    def drop_under(self, folders: list[str]) -> int:
        n = 0
        for f in folders:
            cond, params = self._under_sql(f)
            n += self._delete(f"DELETE FROM claims WHERE {cond}", params)
        return n

    def count_claims_under(self, folders: list[str]) -> int:
        if not self._claims_db or not (os.path.exists(self._claims_db) or self._db):
            return 0
        total = 0
        with self._db_lock:
            db = self._conn()
            if db is None:
                return 0
            for f in folders:
                cond, params = self._under_sql(f)
                total += db.execute(f"SELECT COUNT(*) FROM claims WHERE {cond}", params).fetchone()[0]
        return total

    def gc(self) -> int:
        """Forgets claims for files that no longer exist."""
        if not self._claims_db or not (os.path.exists(self._claims_db) or self._db):
            return 0
        with self._db_lock:
            db = self._conn()
            rows = db.execute("SELECT path FROM claims").fetchall() if db else []
            gone = [p for (p,) in rows if not os.path.exists(p)]
            for p in gone:
                db.execute("DELETE FROM claims WHERE path = ?", (p,))
            if gone:
                db.commit()
        return len(gone)

    def _delete(self, sql: str, params: tuple) -> int:
        if not self._claims_db or not (os.path.exists(self._claims_db) or self._db):
            return 0
        with self._db_lock:
            db = self._conn()
            if db is None:
                return 0
            n = db.execute(sql, params).rowcount
            db.commit()
        return n

    def close(self) -> None:
        with self._db_lock:
            if self._db is not None:
                self._db.close()
                self._db = None
