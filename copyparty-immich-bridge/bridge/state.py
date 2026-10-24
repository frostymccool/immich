"""SQLite state store: remembers which files have been imported.

A file is identified by its absolute path; a change in (size, mtime) makes it
a new candidate again. The store must be safe to call from the hook-receiver
thread, the sweep thread, and the worker thread(s) simultaneously.
"""

from __future__ import annotations

import os
import sqlite3
import threading
import time
from dataclasses import dataclass

# Terminal, successful statuses — files in these states are never re-imported
# unless their size/mtime changes.
DONE_STATUSES = ("imported", "duplicate")


@dataclass
class FileRecord:
    path: str
    size: int
    mtime: float
    sha1: str | None
    status: str
    asset_id: str | None
    error: str | None
    attempts: int
    updated_at: float


class StateStore:
    def __init__(self, db_path: str):
        directory = os.path.dirname(db_path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        self._lock = threading.Lock()
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.execute(
            """
            CREATE TABLE IF NOT EXISTS files (
                path       TEXT PRIMARY KEY,
                size       INTEGER NOT NULL,
                mtime      REAL NOT NULL,
                sha1       TEXT,
                status     TEXT NOT NULL,
                asset_id   TEXT,
                error      TEXT,
                attempts   INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL
            )
            """
        )
        self._db.execute("CREATE INDEX IF NOT EXISTS idx_files_status ON files(status)")
        self._db.commit()

    def close(self) -> None:
        with self._lock:
            self._db.close()

    def get(self, path: str) -> FileRecord | None:
        with self._lock:
            row = self._db.execute(
                "SELECT path, size, mtime, sha1, status, asset_id, error, attempts, updated_at "
                "FROM files WHERE path = ?",
                (path,),
            ).fetchone()
        return FileRecord(*row) if row else None

    def is_done(self, path: str, size: int, mtime: float) -> bool:
        """True when this exact (path, size, mtime) already imported/duplicate."""
        rec = self.get(path)
        if rec is None or rec.status not in DONE_STATUSES:
            return False
        return rec.size == size and abs(rec.mtime - mtime) < 1.0

    def attempts_exhausted(self, path: str, size: int, mtime: float, max_attempts: int) -> bool:
        """True when this exact file version has permanently failed."""
        rec = self.get(path)
        if rec is None or rec.status != "failed":
            return False
        return rec.size == size and abs(rec.mtime - mtime) < 1.0 and rec.attempts >= max_attempts

    def record_success(
        self,
        path: str,
        size: int,
        mtime: float,
        sha1: str,
        status: str,
        asset_id: str | None,
    ) -> None:
        assert status in DONE_STATUSES
        self._upsert(path, size, mtime, sha1, status, asset_id, None, reset_attempts=True)

    def record_skip(self, path: str, size: int, mtime: float, reason: str) -> None:
        self._upsert(path, size, mtime, None, "skipped", None, reason, reset_attempts=True)

    def record_failure(self, path: str, size: int, mtime: float, sha1: str | None, error: str) -> None:
        with self._lock:
            row = self._db.execute("SELECT attempts, size, mtime FROM files WHERE path = ?", (path,)).fetchone()
            # Attempts count per file VERSION: a changed file starts over.
            prev_attempts = row[0] if row and row[1] == size and abs(row[2] - mtime) < 1.0 else 0
            self._db.execute(
                "INSERT INTO files (path, size, mtime, sha1, status, asset_id, error, attempts, updated_at) "
                "VALUES (?, ?, ?, ?, 'failed', NULL, ?, ?, ?) "
                "ON CONFLICT(path) DO UPDATE SET size=excluded.size, mtime=excluded.mtime, "
                "sha1=excluded.sha1, status='failed', asset_id=NULL, error=excluded.error, "
                "attempts=excluded.attempts, updated_at=excluded.updated_at",
                (path, size, mtime, sha1, error[:500], prev_attempts + 1, time.time()),
            )
            self._db.commit()

    def _upsert(
        self,
        path: str,
        size: int,
        mtime: float,
        sha1: str | None,
        status: str,
        asset_id: str | None,
        error: str | None,
        reset_attempts: bool,
    ) -> None:
        with self._lock:
            self._db.execute(
                "INSERT INTO files (path, size, mtime, sha1, status, asset_id, error, attempts, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?) "
                "ON CONFLICT(path) DO UPDATE SET size=excluded.size, mtime=excluded.mtime, "
                "sha1=excluded.sha1, status=excluded.status, asset_id=excluded.asset_id, "
                "error=excluded.error, updated_at=excluded.updated_at"
                + (", attempts=0" if reset_attempts else ""),
                (path, size, mtime, sha1, status, asset_id, error, time.time()),
            )
            self._db.commit()

    def counts(self) -> dict[str, int]:
        with self._lock:
            rows = self._db.execute("SELECT status, COUNT(*) FROM files GROUP BY status").fetchall()
        return {status: n for status, n in rows}

    def recent(self, limit: int = 20) -> list[FileRecord]:
        with self._lock:
            rows = self._db.execute(
                "SELECT path, size, mtime, sha1, status, asset_id, error, attempts, updated_at "
                "FROM files ORDER BY updated_at DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return [FileRecord(*row) for row in rows]
