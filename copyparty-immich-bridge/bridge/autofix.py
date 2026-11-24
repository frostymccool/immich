"""Automatic place and time-zone correction after import, using the owner's existing Immich library as the reference.

A file is changed only on strong evidence: its true instant is known (the file stores a zone, or name + tag pin it) and
geotagged photos taken around that instant agree on where the owner was. Everything else stays untouched and is listed
for review with the reason, and is looked at again later because new phone photos can settle it. Only Immich's metadata
changes, never the original file. Every change is logged with the values it replaced.
"""

from __future__ import annotations

import json
import logging
import os
import sqlite3
import threading
import time
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from bridge.geofix import haversine_km, neighbour_from_asset, zone_at

log = logging.getLogger(__name__)

WINDOW_S = int(os.environ.get("AUTO_FIX_WINDOW_S", "1800"))  # how far from the file a reference photo may be
CLOSE_S = 600  # one reference photo alone is enough only this close
AGREE_KM = 5.0  # references further apart than this mean the owner was travelling: not safe to pick one
RECHECK_S = 6 * 3600
BATCH = 200


def evaluate(instant: datetime, references: list[dict]) -> tuple[dict | None, str]:
    """(the reference to copy the place from, '') or (None, why not). `instant` and each reference's `utc` are naive UTC."""
    near = sorted(((abs((r["utc"] - instant).total_seconds()), r) for r in references if abs((r["utc"] - instant).total_seconds()) <= WINDOW_S),
                  key=lambda x: x[0])
    if not near:
        return None, f"no geotagged photo within {WINDOW_S // 60} minutes"
    gap, best = near[0]
    if len(near) < 2 and gap > CLOSE_S:
        return None, f"only one geotagged photo nearby, {round(gap / 60)} minutes away"
    far = max(haversine_km(best["lat"], best["lon"], r["lat"], r["lon"]) for _, r in near)
    if far > AGREE_KM:
        return None, f"nearby photos disagree by {far:.0f} km (travelling)"
    return best, ""


class AutoFix:
    def __init__(self, db_path: str, geofix, state, client):
        self._gf, self._state, self._client = geofix, state, client
        self._lock = threading.Lock()
        self._running = False
        self.last_run = 0.0
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.execute("""CREATE TABLE IF NOT EXISTS autofix (asset_id TEXT PRIMARY KEY, path TEXT, status TEXT, reason TEXT,
            lat REAL, lon REAL, zone TEXT, new_time TEXT, old_time TEXT, old_zone TEXT, source_asset TEXT, gap_s INTEGER,
            checked_at REAL, applied_at REAL)""")
        self._db.commit()

    def close(self) -> None:
        with self._lock:
            self._db.close()

    def _save(self, asset_id: str, path: str, status: str, reason: str = "", **kw) -> None:
        with self._lock:
            self._db.execute("""INSERT OR REPLACE INTO autofix (asset_id,path,status,reason,lat,lon,zone,new_time,old_time,old_zone,
                source_asset,gap_s,checked_at,applied_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (asset_id, path, status, reason, kw.get("lat"), kw.get("lon"), kw.get("zone"), kw.get("new_time"), kw.get("old_time"),
                 kw.get("old_zone"), kw.get("source_asset"), kw.get("gap_s"), time.time(), kw.get("applied_at")))
            self._db.commit()

    def _todo(self) -> list[tuple[str, str]]:
        with self._lock:
            seen = {r[0]: (r[1], r[2]) for r in self._db.execute("SELECT asset_id,status,checked_at FROM autofix")}
        cutoff = time.time() - RECHECK_S
        out = [(p, a) for p, a in self._state.imported_assets()
               if a not in seen or (seen[a][0] == "review" and seen[a][1] < cutoff)]
        return out[:BATCH]

    def _references(self, instant: datetime, asset_id: str) -> list[dict]:
        with self._lock:
            ours = {r[0] for r in self._db.execute("SELECT asset_id FROM autofix WHERE status='applied'")}  # never chain guesses
        reach = timedelta(seconds=WINDOW_S)
        out, page = [], 1
        while page:
            body = {"takenAfter": (instant - reach).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                    "takenBefore": (instant + reach).strftime("%Y-%m-%dT%H:%M:%S.000Z"), "withExif": True, "size": 500, "page": page}
            assets = (self._client.search_metadata(body) or {}).get("assets") or {}
            for a in assets.get("items") or []:
                if a.get("id") != asset_id and a.get("id") not in ours:
                    n = neighbour_from_asset(a)
                    if n is not None:
                        out.append(n)
            page = int(assets["nextPage"]) if assets.get("nextPage") else None
        return out

    def fix_one(self, path: str, asset_id: str) -> str:
        if not os.path.exists(path):
            self._save(asset_id, path, "review", "the file is no longer in the folder")
            return "review"
        asset = self._client.get_asset(asset_id)
        exif = asset.get("exifInfo") or {}
        if exif.get("latitude") is not None and exif.get("longitude") is not None:
            self._save(asset_id, path, "has_place")
            return "has_place"
        f = self._gf._read_metadata([path])[0]
        if f["taken"] is None:
            self._save(asset_id, path, "review", f.get("date_why") or "no capture time in the file")
            return "review"
        if f["offset_min"] is None:
            self._save(asset_id, path, "review", "the camera's clock has no time zone, so its true time is not known")
            return "review"
        instant = f["taken"] - timedelta(minutes=f["offset_min"])
        best, why = evaluate(instant, self._references(instant, asset_id))
        if best is None:
            self._save(asset_id, path, "review", why)
            return "review"
        zone = best["zone"] if "/" in (best["zone"] or "") else zone_at(best["lat"], best["lon"])
        fields: dict = {"latitude": best["lat"], "longitude": best["lon"]}
        new_time = ""
        try:
            if zone:  # same instant, shown in the local time of the place
                new_time = instant.replace(tzinfo=timezone.utc).astimezone(ZoneInfo(zone)).isoformat()
                fields["dateTimeOriginal"] = new_time
        except (ValueError, ZoneInfoNotFoundError, OSError):
            new_time = ""
        self._client.update_asset(asset_id, fields)
        self._save(asset_id, path, "applied", lat=best["lat"], lon=best["lon"], zone=zone, new_time=new_time,
                   old_time=exif.get("dateTimeOriginal"), old_zone=exif.get("timeZone"), source_asset=best["id"],
                   gap_s=int(abs((best["utc"] - instant).total_seconds())), applied_at=time.time())
        log.info("auto-fix: %s placed from a photo %d min away", os.path.basename(path), abs((best["utc"] - instant).total_seconds()) // 60)
        return "applied"

    def run_once(self) -> dict:
        with self._lock:
            if self._running:
                return {"running": True}
            self._running = True
        counts: dict[str, int] = {}
        try:
            for path, asset_id in self._todo():
                try:
                    r = self.fix_one(path, asset_id)
                except Exception as ex:  # one bad file or a brief Immich error must not stop the pass; it is retried later
                    log.warning("auto-fix failed for %s: %s", os.path.basename(path), ex)
                    self._save(asset_id, path, "review", f"could not be checked: {str(ex)[:120]}")
                    r = "error"
                counts[r] = counts.get(r, 0) + 1
        finally:
            self.last_run = time.time()
            with self._lock:
                self._running = False
        if counts:
            log.info("auto-fix pass: %s", json.dumps(counts, sort_keys=True))
        return counts

    def describe(self, limit: int = 200) -> dict:
        with self._lock:
            counts = dict(self._db.execute("SELECT status,count(*) FROM autofix GROUP BY status").fetchall())
            reasons = dict(self._db.execute("SELECT reason,count(*) FROM autofix WHERE status='review' GROUP BY reason").fetchall())
            review = [{"asset": a, "name": os.path.basename(p), "reason": r} for a, p, r in self._db.execute(
                "SELECT asset_id,path,reason FROM autofix WHERE status='review' ORDER BY path LIMIT ?", (limit,))]
            applied = [{"asset": a, "name": os.path.basename(p), "lat": la, "lon": lo, "zone": z, "gap_s": g, "old_time": o, "new_time": n}
                       for a, p, la, lo, z, g, o, n in self._db.execute(
                           "SELECT asset_id,path,lat,lon,zone,gap_s,old_time,new_time FROM autofix WHERE status='applied' ORDER BY applied_at DESC LIMIT ?", (limit,))]
            running = self._running
        return {"running": running, "last_run": self.last_run, "counts": counts, "reasons": reasons, "review": review, "applied": applied}
