"""Stack a camera RAW with the JPG/HEIC the camera saved next to it, so Immich shows one picture with the RAW behind it.

The same rules as the phone app (so both make the same stacks):
- same folder in Immich's library and the same name ignoring case and extension;
- exactly one RAW and at least one JPG/HEIC, every member in Immich and none already in a stack;
- the JPG (then HEIC) first: Immich makes the first id the cover;
- once per pair; a refusal is only logged (and not tried again); a busy or unreachable Immich is tried next sweep.

The first sweep looks at the whole library; later sweeps at what Immich received since (and their partners, which may
be older). Main account only, like the other automatic changes."""

from __future__ import annotations

import logging
import os
import re
import sqlite3
import threading
import time
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from typing import Callable

import requests

from bridge.immich import ImmichError

log = logging.getLogger(__name__)

RAW_EXT = {"dng", "nef", "nrw", "orf", "arw", "cr2", "cr3", "rw2", "raf", "raw", "pef", "srw"}
COVER_EXT = ("jpg", "jpeg", "heic", "heif")  # cover preference, best first
PAGE = 1000
OVERLAP = timedelta(days=1)  # look back a little before the last sweep: uploads that were in flight


def _split(name: str) -> tuple[str, str]:
    stem, dot, ext = (name or "").rpartition(".")
    return (stem.lower(), ext.lower()) if dot else ((name or "").lower(), "")


def pair_key(asset: dict) -> tuple[str, str] | None:
    """(folder, name) of a RAW or JPG/HEIC asset, or None for anything else."""
    stem, ext = _split(asset.get("originalFileName", ""))
    if not stem or (ext not in RAW_EXT and ext not in COVER_EXT):
        return None
    return os.path.dirname(asset.get("originalPath") or ""), stem


def stack_order(members: list[dict]) -> list[str] | None:
    """The ids to stack, cover first, or None when these files are not one RAW with its JPG/HEIC."""
    if any(m.get("stack") or m.get("isTrashed") for m in members):
        return None  # already stacked (a burst, or by hand): left as it is
    raws = [m for m in members if _split(m["originalFileName"])[1] in RAW_EXT]
    covers = [m for m in members if _split(m["originalFileName"])[1] in COVER_EXT]
    if len(raws) != 1 or not covers:
        return None
    covers.sort(key=lambda m: COVER_EXT.index(_split(m["originalFileName"])[1]))
    return [m["id"] for m in covers] + [raws[0]["id"]]


class RawStacker:
    def __init__(self, db_path: str, client, busy: Callable[[], bool] = lambda: False, clock: Callable[[], float] = time.time):
        self._client = client
        self._busy = busy
        self._clock = clock
        self._lock = threading.Lock()
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.execute("""CREATE TABLE IF NOT EXISTS pairs (ids TEXT PRIMARY KEY, name TEXT, state TEXT, stack_id TEXT,
            reason TEXT, at REAL)""")
        self._db.execute("CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT)")
        self._db.commit()
        self.enabled: Callable[[], bool] = lambda: True

    # -- finding pairs ---------------------------------------------------------------------------------

    def _search(self, body: dict) -> list[dict]:
        out, page = [], 1
        while page:
            got = (self._client.search_metadata({**body, "withStacked": True, "size": PAGE, "page": page}).get("assets") or {})
            out += got.get("items") or []
            page = int(got["nextPage"]) if got.get("nextPage") else 0
        return out

    def find_pairs(self, since: str | None) -> list[tuple[str, list[str]]]:
        """(name, ids cover first) for every RAW pair among what Immich received since `since` (everything if None)."""
        fresh = self._search({"createdAfter": since} if since else {})
        groups: dict[tuple[str, str], dict[str, dict]] = defaultdict(dict)
        for a in fresh:
            k = pair_key(a)
            if k:
                groups[k][a["id"]] = a
        if since:  # a new JPG's RAW (or the other way round) may have come in long before
            for (folder, stem), members in list(groups.items()):
                names = {_split(m["originalFileName"])[1] for m in members.values()}
                if names & RAW_EXT and names & set(COVER_EXT):
                    continue
                for a in self._search({"originalFileName": stem}):
                    if pair_key(a) == (folder, stem):
                        members[a["id"]] = a
        out = []
        for (_, stem), members in sorted(groups.items()):
            ids = stack_order(list(members.values()))
            if ids:
                out.append((next(m["originalFileName"] for m in members.values() if m["id"] == ids[-1]), ids))
        return out

    # -- stacking --------------------------------------------------------------------------------------

    def _known(self, ids: list[str]) -> bool:
        with self._lock:
            return self._db.execute("SELECT 1 FROM pairs WHERE ids=?", (",".join(sorted(ids)),)).fetchone() is not None

    def _record(self, ids: list[str], name: str, state: str, stack_id: str | None, reason: str) -> None:
        with self._lock:
            self._db.execute("INSERT OR REPLACE INTO pairs VALUES (?,?,?,?,?,?)",
                             (",".join(sorted(ids)), name, state, stack_id, reason, self._clock()))
            self._db.commit()

    def run_once(self, limit: int | None = None, dry: bool = False) -> dict:
        """One sweep. Returns counts; `limit` stops after that many new stacks, `dry` only lists them."""
        counts = {"stacked": 0, "refused": 0, "known": 0, "planned": [], "held": False}
        with self._lock:
            row = self._db.execute("SELECT v FROM meta WHERE k='since'").fetchone()
        started = datetime.fromtimestamp(self._clock(), timezone.utc)
        since = (datetime.fromisoformat(row[0]) - OVERLAP).isoformat() if row else None
        finished = True
        for name, ids in self.find_pairs(since):
            if self._known(ids):
                counts["known"] += 1
                continue
            if dry:
                counts["planned"].append({"name": name, "ids": ids})
                continue
            if limit is not None and counts["stacked"] >= limit:
                finished = False
                break
            if self._busy():
                counts["held"], finished = True, False
                break
            try:
                st = self._client.create_stack(ids)
            except (requests.RequestException, ImmichError) as ex:
                msg = str(ex)
                code = re.search(r"HTTP (\d{3})", msg)
                if not (code and code.group(1).startswith("4")):  # unreachable, busy, or the key itself refused
                    (log.warning if "permission" in msg or "not valid" in msg else log.info)(
                        "stacking %s held for the next sweep: %s", name, msg[:200])
                    finished = False
                    break
                log.warning("Immich would not stack %s with its JPG: %s", name, msg[:200])
                self._record(ids, name, "refused", None, msg[:300])
                counts["refused"] += 1
                continue
            self._record(ids, name, "stacked", st.get("id"), "")
            counts["stacked"] += 1
        if finished and not dry:
            with self._lock:
                self._db.execute("INSERT OR REPLACE INTO meta VALUES ('since', ?)", (started.isoformat(),))
                self._db.commit()
        if counts["stacked"] or counts["refused"]:
            log.info("RAW stacks: %d made, %d refused by Immich", counts["stacked"], counts["refused"])
        return counts

    def describe(self) -> dict:
        with self._lock:
            c = dict(self._db.execute("SELECT state, COUNT(*) FROM pairs GROUP BY state").fetchall())
            row = self._db.execute("SELECT v FROM meta WHERE k='since'").fetchone()
        return {"on": bool(self.enabled()), "stacked": c.get("stacked", 0), "refused": c.get("refused", 0),
                "last_sweep": row[0] if row else None}

    def close(self) -> None:
        with self._lock:
            self._db.close()
