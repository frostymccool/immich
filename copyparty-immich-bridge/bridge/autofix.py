"""Automatic place, time and time-zone correction after import, using the owner's existing Immich library as reference.

A file is changed only on strong evidence. Only Immich's metadata changes, never the original file, and every change
is logged with the values it replaced (table `changes`).

- **Time from the file.** When the file pins its true instant (a stored zone, a GoPro HERO11+ zone tag with its UTC
  clock, an Insta360 name + tag) and Immich shows a different one, the time is corrected even if no place is found.
- **Place.** Geotagged photos within 30 minutes of the true instant that agree on one spot give the place; failing
  that, geotagged photos within 3 hours that LOOK like this one (Immich's own image model) and agree on one spot
  ("the same outing").
- **A camera whose clock is set wrong** (no zone stored, or a clock left on another zone, or simply wrong): pictures
  from that camera are matched with pictures from devices with a trusted clock, taken at the SAME MOMENT (image
  similarity of Immich's CLIP model at or above `AUTO_FIX_SAME_MOMENT`). When at least 3 such pairs agree within
  3 minutes on the camera's offset, every file of that camera in that folder is corrected by it.

Everything else stays untouched and is listed for review with the reason, and is looked at again later because new
photos can settle it.
"""

from __future__ import annotations

import json
import logging
import math
import os
import sqlite3
import statistics
import threading
import time
from collections import Counter
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from bridge.geofix import _iso_utc, haversine_km, neighbour_from_asset, parse_exif_time, zone_at
from bridge.pressure import PRESSURE

log = logging.getLogger(__name__)

WINDOW_S = int(os.environ.get("AUTO_FIX_WINDOW_S", "1800"))  # how far from the file a reference photo may be
CLOSE_S = 600  # one reference photo alone is enough only this close
AGREE_KM = 5.0  # references further apart than this mean the owner was travelling: not safe to pick one
RECHECK_S = 6 * 3600
CLOCK_RECHECK_S = 1800  # an undecided camera clock: new trusted pictures (a clip just corrected) may settle it
RULES_VERSION = 2  # bump when new rules should look at every file waiting for review again
BATCH = 50  # files per pass: each change makes Immich re-read the file, so big passes overload a small server
PAUSE_S = float(os.environ.get("AUTO_FIX_PAUSE_S", "6"))  # between two changes: 50 x 6 s spreads a batch over the 5-minute cycle
SAME_MOMENT = float(os.environ.get("AUTO_FIX_SAME_MOMENT", "0.85"))  # CLIP similarity of two shots of the same moment
LOOKS_LIKE = float(os.environ.get("AUTO_FIX_LOOKS_LIKE", "0.75"))  # same scene, not necessarily the same moment
CLOCK_TOL_S = 180  # same-moment pairs must agree on the camera's offset this closely
CLOCK_MIN_PAIRS = 3
OUTING_S = 3 * 3600
MAX_CLOCK_S = 26 * 3600
SAMPLE = 80  # pictures of one camera compared with the references
MAX_REFS = 400
NO_ZONE = "the camera's clock has no time zone, so its true time is not known"


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


def clock_offset_from_pairs(offsets: list[float]) -> tuple[float | None, int, str]:
    """(camera clock minus true UTC in seconds, pairs that agree, why not). `offsets` = one per same-moment pair."""
    if len(offsets) < CLOCK_MIN_PAIRS:
        return None, len(offsets), f"only {len(offsets)} picture(s) match another device's picture of the same moment (need {CLOCK_MIN_PAIRS})"
    xs = sorted(offsets)
    best: list[float] = []
    j = 0
    for i in range(len(xs)):
        while xs[i] - xs[j] > 2 * CLOCK_TOL_S:
            j += 1
        if i - j + 1 > len(best):
            best = xs[j : i + 1]
    if len(best) < CLOCK_MIN_PAIRS or len(best) < 0.6 * len(xs):
        return None, len(best), f"{len(xs)} same-moment matches do not agree on one clock offset"
    off = statistics.median(best)
    if abs(off) > MAX_CLOCK_S:
        return None, len(best), "the matches put the camera's clock more than a day off"
    return off, len(best), ""


def describe_offset(seconds: float) -> str:
    s = int(round(abs(seconds)))
    h, m, sec = s // 3600, s % 3600 // 60, s % 60
    parts = [f"{h} h" if h else "", f"{m} min" if m else "", f"{sec} s" if sec and not h else ""]
    return (" ".join(p for p in parts if p) or "0 s") + (" behind" if seconds < 0 else " ahead of") + (" UTC" if seconds < 0 else " UTC")


def tz_of(hint: str):
    """An IANA name or 'UTC±HH:MM' -> tzinfo, else None."""
    if not hint:
        return None
    if "/" in hint:
        try:
            return ZoneInfo(hint)
        except (ValueError, ZoneInfoNotFoundError, OSError):
            return None
    if hint.startswith("UTC") and len(hint) > 3:
        try:
            sign = -1 if hint[3] == "-" else 1
            hh, _, mm = hint[4:].partition(":")
            return timezone(sign * timedelta(hours=int(hh), minutes=int(mm or 0)))
        except ValueError:
            return None
    return None


def _cos(a: list[float], b: list[float]) -> float:
    return sum(x * y for x, y in zip(a, b))


class AutoFix:
    def __init__(self, db_path: str, geofix, state, client, embed=None):
        self._gf, self._state, self._client = geofix, state, client
        self.embed = embed  # JPEG bytes -> CLIP vector (Immich machine learning), or None: no picture matching
        self._lock = threading.Lock()
        self._running = False
        self.last_run = 0.0
        self.enabled = lambda: False  # set by the app: the auto_fix setting
        self._outings: dict = {}
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.execute("""CREATE TABLE IF NOT EXISTS autofix (asset_id TEXT PRIMARY KEY, path TEXT, status TEXT, reason TEXT,
            lat REAL, lon REAL, zone TEXT, new_time TEXT, old_time TEXT, old_zone TEXT, source_asset TEXT, gap_s INTEGER,
            checked_at REAL, applied_at REAL)""")
        if "basis" not in {r[1] for r in self._db.execute("PRAGMA table_info(autofix)")}:
            self._db.execute("ALTER TABLE autofix ADD COLUMN basis TEXT")  # 'file' = time proven by the file; 'matched' = inferred
        self._db.execute("""CREATE TABLE IF NOT EXISTS changes (asset_id TEXT, at REAL, field TEXT, old TEXT, new TEXT, why TEXT)""")
        self._db.execute("""CREATE TABLE IF NOT EXISTS clocks (folder TEXT, camera TEXT, status TEXT, offset_s REAL, zone TEXT,
            pairs INTEGER, reason TEXT, checked_at REAL, PRIMARY KEY (folder, camera))""")
        self._db.execute("CREATE TABLE IF NOT EXISTS embeds (asset_id TEXT PRIMARY KEY, vec TEXT)")
        if self._db.execute("PRAGMA user_version").fetchone()[0] < RULES_VERSION:
            self._db.execute("UPDATE autofix SET checked_at=0, status='review' WHERE status IN ('review','has_place')")
            self._db.execute(f"PRAGMA user_version={RULES_VERSION}")
        self._db.commit()

    def close(self) -> None:
        with self._lock:
            self._db.close()

    def _save(self, asset_id: str, path: str, status: str, reason: str = "", **kw) -> None:
        with self._lock:
            self._db.execute("""INSERT OR REPLACE INTO autofix (asset_id,path,status,reason,lat,lon,zone,new_time,old_time,old_zone,
                source_asset,gap_s,checked_at,applied_at,basis) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (asset_id, path, status, reason, kw.get("lat"), kw.get("lon"), kw.get("zone"), kw.get("new_time"), kw.get("old_time"),
                 kw.get("old_zone"), kw.get("source_asset"), kw.get("gap_s"), time.time(), kw.get("applied_at"), kw.get("basis")))
            self._db.commit()

    def _log_change(self, asset_id: str, field: str, old, new, why: str) -> None:
        with self._lock:
            self._db.execute("INSERT INTO changes VALUES (?,?,?,?,?,?)", (asset_id, time.time(), field, None if old is None else str(old),
                                                                          None if new is None else str(new), why))
            self._db.commit()

    def _todo(self) -> list[tuple[str, str]]:
        with self._lock:
            seen = {r[0]: (r[1], r[2]) for r in self._db.execute("SELECT asset_id,status,checked_at FROM autofix")}
        cutoff = time.time() - RECHECK_S
        out = [(p, a) for p, a in self._state.imported_assets()
               if a not in seen or (seen[a][0] == "review" and seen[a][1] < cutoff)]
        return out[-BATCH:]  # the newest imports (what people look at), still in import order within the batch

    # -- Immich lookups ---------------------------------------------------------------------------------------------

    def _assets_between(self, start: datetime, end: datetime) -> list[dict]:
        out, page = [], 1
        while page:
            body = {"takenAfter": start.strftime("%Y-%m-%dT%H:%M:%S.000Z"), "takenBefore": end.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                    "withExif": True, "size": 500, "page": page}
            assets = (self._client.search_metadata(body) or {}).get("assets") or {}
            out.extend(assets.get("items") or [])
            page = int(assets["nextPage"]) if assets.get("nextPage") else None
        return out

    def _guessed(self) -> set[str]:
        """Assets whose place or time THIS bridge inferred: never used as evidence for another guess."""
        with self._lock:
            return {r[0] for r in self._db.execute(
                "SELECT asset_id FROM autofix WHERE (status='applied' AND source_asset IS NOT NULL) OR basis='matched'")}

    def _references(self, instant: datetime, asset_id: str, reach_s: int = WINDOW_S) -> list[dict]:
        ours = self._guessed()
        reach = timedelta(seconds=reach_s)
        out = []
        for a in self._assets_between(instant - reach, instant + reach):
            if a.get("id") != asset_id and a.get("id") not in ours:
                n = neighbour_from_asset(a)
                if n is not None:
                    out.append(n)
        return out

    def _vec(self, asset_id: str) -> list[float] | None:
        with self._lock:
            row = self._db.execute("SELECT vec FROM embeds WHERE asset_id=?", (asset_id,)).fetchone()
        if row:
            return json.loads(row[0])
        if self.embed is None or PRESSURE.busy:
            return None
        try:
            data, _ = self._client.thumbnail(asset_id)
            v = self.embed(data)
        except Exception as ex:  # noqa: BLE001 - a missing preview just leaves that picture out
            log.debug("no picture for %s: %s", asset_id, ex)
            return None
        n = math.sqrt(sum(x * x for x in v)) or 1.0
        v = [round(x / n, 6) for x in v]
        with self._lock:
            self._db.execute("INSERT OR REPLACE INTO embeds VALUES (?,?)", (asset_id, json.dumps(v)))
            self._db.commit()
        return v

    # -- one file ---------------------------------------------------------------------------------------------------

    def _clock_for(self, f: dict) -> tuple[float, str] | None:
        with self._lock:
            row = self._db.execute("SELECT offset_s, zone FROM clocks WHERE folder=? AND camera=? AND status='decided'",
                                   (f["folder"], f["camera"])).fetchone()
        return (row[0], row[1] or "") if row else None

    def _outing_place(self, asset_id: str, instant: datetime) -> tuple[dict | None, str]:
        """Geotagged photos within 3 hours that look like this one and agree on one spot."""
        if self.embed is None:
            return None, ""
        mine = self._vec(asset_id)
        if mine is None:
            return None, ""
        alike = []
        for n in self._references(instant, asset_id, OUTING_S):
            v = self._vec(n["id"])
            if v is not None and _cos(mine, v) >= LOOKS_LIKE:
                alike.append(n)
        if len(alike) < 2:
            return None, f"{len(alike)} look-alike geotagged photo(s) within {OUTING_S // 3600} hours"
        lat = statistics.median(n["lat"] for n in alike)
        lon = statistics.median(n["lon"] for n in alike)
        if max(haversine_km(lat, lon, n["lat"], n["lon"]) for n in alike) > AGREE_KM:
            return None, "look-alike photos from that outing are in different places"
        near = min(alike, key=lambda n: abs((n["utc"] - instant).total_seconds()))
        return {**near, "lat": lat, "lon": lon, "outing": len(alike)}, ""

    def _zone_nearby(self, instant: datetime, asset_id: str) -> str:
        """The zone the owner's devices with a trusted clock recorded within 3 hours, when they all agree; else ''."""
        with self._lock:
            ours = {r[0]: (r[1], r[2] or "", r[3] or "") for r in self._db.execute("SELECT asset_id,status,reason,basis FROM autofix")}
        offsets: Counter = Counter()
        names: dict[int, Counter] = {}
        reach = timedelta(seconds=OUTING_S)
        for a in self._assets_between(instant - reach, instant + reach):
            if a.get("id") == asset_id or not self._trusted_clock(a, ours):
                continue
            utc, local = _iso_utc(a.get("fileCreatedAt")), _iso_utc(a.get("localDateTime"))
            if utc is None or local is None:
                continue
            off = int(round((local - utc).total_seconds() / 900.0)) * 15
            offsets[off] += 1
            zone = (a.get("exifInfo") or {}).get("timeZone") or ""
            if "/" in zone:
                names.setdefault(off, Counter())[zone] += 1
        if len(offsets) != 1:
            return ""  # none, or the owner crossed zones around then
        off = next(iter(offsets))
        if off in names:
            return names[off].most_common(1)[0][0]
        return f"UTC{'+' if off >= 0 else '-'}{abs(off) // 60:02d}:{abs(off) % 60:02d}"

    def _instant_of(self, f: dict) -> tuple[datetime | None, str]:
        if f["taken"] is None:
            return None, ""
        if f["offset_min"] is not None:
            return f["taken"] - timedelta(minutes=f["offset_min"]), "file"
        clock = self._clock_for(f) or self._sibling_clock(f)
        return (f["taken"] - timedelta(seconds=clock[0]), "matched") if clock else (None, "")

    def _sibling_clock(self, f: dict) -> tuple[float, str] | None:
        """A clip with no zone next to clips of the same numbered series whose UTC clock the file proves (GoPro zone tag):
        an exported or trimmed copy loses the tag but keeps the camera's UTC clock."""
        if not f["video"] or f["counter"] is None:
            return None
        paths = [p for p, _ in self._state.imported_assets() if os.path.dirname(p) == f["folder"]]
        for g in self._gf._read_metadata(paths):
            if (g["path"] == f["path"] or not g["video"] or g["offset_min"] is None or g["counter"] is None
                    or g["name"][:4].lower() != f["name"][:4].lower() or abs(g["counter"] - f["counter"]) > 5):
                continue
            raw, _ = parse_exif_time(g["clock_raw"])
            if raw is None or abs((raw - (g["taken"] - timedelta(minutes=g["offset_min"]))).total_seconds()) > 1:
                continue  # that clip's tag is not a UTC clock
            if abs((f["taken"] - raw).total_seconds()) > 2 * 3600:
                continue
            m = g["offset_min"]
            return 0.0, f"UTC{'+' if m >= 0 else '-'}{abs(m) // 60:02d}:{abs(m) % 60:02d}"
        return None

    def _outing_of_group(self, f: dict) -> tuple[dict | None, str]:
        """The place of a whole outing: the files of this camera in this folder (true times known, no gap over 3 hours)
        and the owner's geotagged photos from 3 hours before to 3 hours after it that LOOK like those files. All of
        those must agree on one spot; any look-alike photo elsewhere means no place."""
        key = (f["folder"], f["camera"])
        hit = self._outings.get(key)
        if hit and time.time() - hit[0] < CLOCK_RECHECK_S:
            return hit[1], hit[2]
        place, why = self._outing_place_now(f)
        self._outings[key] = (time.time(), place, why)
        return place, why

    def _outing_place_now(self, f: dict) -> tuple[dict | None, str]:
        if self.embed is None:
            return None, ""
        paths = {p: a for p, a in self._state.imported_assets() if os.path.dirname(p) == f["folder"]}
        members = []
        for m in self._gf._read_metadata(list(paths)):
            if m["camera"] == f["camera"]:
                t, _ = self._instant_of(m)
                if t is not None:
                    members.append((t, paths[m["path"]]))
        if not members:
            return None, ""
        members.sort()
        if any((b[0] - a[0]).total_seconds() > OUTING_S for a, b in zip(members, members[1:])):
            return None, "this camera's files in the folder are more than one outing"
        start, end = members[0][0], members[-1][0]
        if (end - start).total_seconds() > 24 * 3600:
            return None, "this camera's files in the folder cover more than a day"
        ids = {a for _, a in members}
        step = max(1, len(members) // SAMPLE)
        vecs = [v for v in (self._vec(a) for _, a in members[::step][:SAMPLE]) if v is not None]
        if not vecs:
            return None, ""
        mid = start + (end - start) / 2
        refs = [n for n in self._references(mid, "", int((end - start).total_seconds() / 2) + OUTING_S) if n["id"] not in ids]
        alike = []
        for n in refs:
            v = self._vec(n["id"])
            if v is not None and max(_cos(v, m) for m in vecs) >= LOOKS_LIKE:
                alike.append(n)
        if len(alike) < 2:
            return None, f"{len(alike)} look-alike geotagged photo(s) from that outing"
        lat = statistics.median(n["lat"] for n in alike)
        lon = statistics.median(n["lon"] for n in alike)
        far = max(haversine_km(lat, lon, n["lat"], n["lon"]) for n in alike)
        if far > AGREE_KM:
            return None, f"look-alike photos from that outing are {far:.0f} km apart"
        near = min(alike, key=lambda n: abs((n["utc"] - mid).total_seconds()))
        return {**near, "lat": lat, "lon": lon, "outing": len(alike)}, ""

    def fix_one(self, path: str, asset_id: str) -> str:
        if not os.path.exists(path):
            self._save(asset_id, path, "review", "the file is no longer in the folder")
            return "review"
        asset = self._client.get_asset(asset_id)
        exif = asset.get("exifInfo") or {}
        has_place = exif.get("latitude") is not None and exif.get("longitude") is not None
        f = self._gf._read_metadata([path])[0]
        if f["taken"] is None:
            if has_place:
                self._save(asset_id, path, "has_place")
                return "has_place"
            self._save(asset_id, path, "review", f.get("date_why") or "no capture time in the file")
            return "review"
        offset_s, zone_hint, basis, time_why = None, "", "file", "clock read from the file"
        if f["offset_min"] is not None:
            offset_s = f["offset_min"] * 60
            zone_hint = f"UTC{'+' if offset_s >= 0 else '-'}{abs(f['offset_min']) // 60:02d}:{abs(f['offset_min']) % 60:02d}"
        else:
            clock = self._clock_for(f)
            if clock is not None:
                offset_s, zone_hint = clock
                basis, time_why = "matched", f"camera clock {describe_offset(offset_s)}, from pictures of the same moment"
            else:
                clock = self._sibling_clock(f)
                if clock is not None:
                    offset_s, zone_hint = clock
                    basis, time_why = "matched", "UTC clock like the clips numbered next to it (their files prove it)"
        if offset_s is None:
            if has_place:
                self._save(asset_id, path, "has_place")
                return "has_place"
            self._save(asset_id, path, "review", NO_ZONE)
            return "review"
        instant = f["taken"] - timedelta(seconds=offset_s)
        shown = _iso_utc(exif.get("dateTimeOriginal"))
        instant_wrong = shown is not None and abs((shown - instant).total_seconds()) > 60

        place, why, place_why = None, "", ""
        if not has_place:
            place, why = evaluate(instant, self._references(instant, asset_id))
            place_why = "" if place is None else f"place from a photo {round(abs((place['utc'] - instant).total_seconds()) / 60)} min away"
            if place is None:
                place, why2 = self._outing_place(asset_id, instant)
                if place is None:
                    place, why3 = self._outing_of_group(f)
                    why2 = "; ".join(x for x in (why2, why3) if x)
                if place is not None:
                    place_why = f"place from {place['outing']} look-alike photos taken that outing"
                else:
                    why = "; ".join(x for x in (why, why2) if x)
        lat, lon = (place["lat"], place["lon"]) if place else (exif.get("latitude"), exif.get("longitude"))
        zone = ""
        if lat is not None and lon is not None:
            zone = (place or {}).get("zone") if "/" in ((place or {}).get("zone") or "") else zone_at(lat, lon)
        zone_from_camera = False
        if not zone:
            zone = self._zone_nearby(instant, asset_id)
        if not zone:  # only the camera's own zone setting, which may be left on another trip's zone
            zone, zone_from_camera = zone_hint, True
        tz = tz_of(zone or "")
        shown_utc, shown_local = _iso_utc(asset.get("fileCreatedAt")), _iso_utc(asset.get("localDateTime"))
        zone_wrong = bool(tz and shown_utc and shown_local and not zone_from_camera) and abs(
            (shown_local - shown_utc).total_seconds() - instant.replace(tzinfo=timezone.utc).astimezone(tz).utcoffset().total_seconds()) > 60
        time_wrong = instant_wrong or zone_wrong  # the instant, or the local time Immich shows for it
        if has_place and not time_wrong:
            self._save(asset_id, path, "has_place")
            return "has_place"
        if place is None and not time_wrong:
            self._save(asset_id, path, "review", why)
            return "review"
        fields: dict = {}
        if place is not None:
            fields.update(latitude=lat, longitude=lon)
        new_time = instant.replace(tzinfo=timezone.utc).astimezone(tz).isoformat() if tz else instant.strftime("%Y-%m-%dT%H:%M:%S+00:00")
        fields["dateTimeOriginal"] = new_time
        self._client.update_asset(asset_id, fields)
        if time_wrong:
            self._log_change(asset_id, "dateTimeOriginal", exif.get("dateTimeOriginal"), new_time, time_why)
        if place is not None:
            self._log_change(asset_id, "place", None, f"{lat:.5f},{lon:.5f}", place_why)
        gap = int(abs((place["utc"] - instant).total_seconds())) if place else None
        done = place is not None or has_place
        if done:
            self._save(asset_id, path, "applied", lat=lat, lon=lon, zone=zone, new_time=new_time, old_time=exif.get("dateTimeOriginal"),
                       old_zone=exif.get("timeZone"), source_asset=(place or {}).get("id"), gap_s=gap, applied_at=time.time(), basis=basis)
        else:
            self._save(asset_id, path, "review", f"time corrected ({time_why}); no place yet: {why}", zone=zone, new_time=new_time,
                       old_time=exif.get("dateTimeOriginal"), old_zone=exif.get("timeZone"), applied_at=time.time(), basis=basis)
        log.info("auto-fix: %s %s%s", os.path.basename(path), "time corrected, " if time_wrong else "",
                 place_why or ("no place yet" if not has_place else "place kept"))
        return "applied" if done else "time_fixed"

    # -- cameras with a wrong clock ---------------------------------------------------------------------------------

    def _trusted_clock(self, a: dict, ours: dict[str, tuple[str, str, str]]) -> bool:
        row = ours.get(a.get("id"))
        if row is not None:  # imported by this bridge: trusted only once its time is proven by the file itself
            status, reason, basis = row
            return basis == "file" or (status == "has_place" and reason == "")
        zone = (a.get("exifInfo") or {}).get("timeZone") or ""
        return bool(zone) and zone not in ("UTC", "UTC+0", "UTC-0")

    def align_clocks(self) -> dict[str, int]:
        """Decides the clock offset of cameras whose files have no zone, folder by folder."""
        with self._lock:
            rows = self._db.execute("SELECT asset_id, path FROM autofix WHERE status='review' AND reason=?", (NO_ZONE,)).fetchall()
            known = {(r[0], r[1]): r[2] for r in self._db.execute("SELECT folder, camera, checked_at FROM clocks")}
        groups: dict[tuple[str, str], list[tuple[str, dict]]] = {}
        paths = [p for _, p in rows if os.path.exists(p)]
        meta = {f["path"]: f for f in self._gf._read_metadata(paths)} if paths else {}
        for asset_id, path in rows:
            f = meta.get(path)
            if f and f["taken"] is not None:
                groups.setdefault((f["folder"], f["camera"]), []).append((asset_id, f))
        counts: dict[str, int] = {}
        for key, members in groups.items():
            if PRESSURE.busy:
                break
            if time.time() - known.get(key, 0) < CLOCK_RECHECK_S:
                continue
            r = self._decide_clock(key, members)
            counts[r] = counts.get(r, 0) + 1
        return counts

    def _decide_clock(self, key: tuple[str, str], members: list[tuple[str, dict]]) -> str:
        folder, camera = key
        if self.embed is None:
            self._save_clock(key, "review", None, "", 0, "no image model to compare pictures (IMMICH_ML_URL)")
            return "review"
        ids = {a for a, _ in members}
        lo = min(f["taken"] for _, f in members)
        hi = max(f["taken"] for _, f in members)
        with self._lock:
            ours = {r[0]: (r[1], r[2] or "", r[3] or "") for r in self._db.execute("SELECT asset_id,status,reason,basis FROM autofix")}
        refs = []
        for a in self._assets_between(lo - timedelta(hours=15), hi + timedelta(hours=15)):
            exif = a.get("exifInfo") or {}
            same_camera = bool(camera and exif.get("model") and camera.endswith(str(exif["model"])))
            if a.get("id") in ids or same_camera or not self._trusted_clock(a, ours):
                continue
            utc = _iso_utc(exif.get("dateTimeOriginal")) or _iso_utc(a.get("fileCreatedAt"))
            if utc is not None:
                refs.append((a["id"], utc, exif.get("timeZone") or "", neighbour_from_asset(a)))
        mid = lo + (hi - lo) / 2
        refs = sorted(refs, key=lambda r: abs((r[1] - mid).total_seconds()))[:MAX_REFS]
        if not refs:
            self._save_clock(key, "review", None, "", 0, "no pictures from a device with a trusted clock within 15 hours")
            return "review"
        step = max(1, len(members) // SAMPLE)
        sample = sorted(members, key=lambda m: m[1]["taken"])[::step][:SAMPLE]
        ref_vecs = []
        for r in refs:
            v = self._vec(r[0])
            if PRESSURE.busy:
                return "held"
            if v is not None:
                ref_vecs.append((r, v))
        offsets, matched = [], []
        for asset_id, f in sample:
            v = self._vec(asset_id)
            if PRESSURE.busy:
                return "held"
            if v is None or not ref_vecs:
                continue
            (rid, utc, rzone, rn), rv = max(ref_vecs, key=lambda x: _cos(v, x[1]))
            if _cos(v, rv) >= SAME_MOMENT:
                offsets.append((f["taken"] - utc).total_seconds())
                matched.append((rzone, rn))
        off, n, why = clock_offset_from_pairs(offsets)
        if off is None:
            self._save_clock(key, "review", None, "", n, why)
            log.info("clock of %s in %s not decided: %s", camera or "camera", os.path.basename(folder), why)
            return "review"
        zones = Counter(z for z, _ in matched if "/" in z) or Counter(zone_at(rn["lat"], rn["lon"]) for _, rn in matched if rn) \
            or Counter(z for z, _ in matched if z)
        zone = zones.most_common(1)[0][0] if zones else ""
        self._save_clock(key, "decided", off, zone or "", n, "")
        with self._lock:  # look at that camera's files again in the next pass
            self._db.executemany("UPDATE autofix SET checked_at=0 WHERE asset_id=?", [(a,) for a in ids])
            self._db.commit()
        log.info("clock of %s in %s: %s, from %d pictures of the same moment", camera or "camera", os.path.basename(folder),
                 describe_offset(off), n)
        return "decided"

    def _save_clock(self, key, status, offset, zone, pairs, reason) -> None:
        with self._lock:
            self._db.execute("INSERT OR REPLACE INTO clocks VALUES (?,?,?,?,?,?,?,?)", (*key, status, offset, zone, pairs, reason, time.time()))
            self._db.commit()

    # -- passes ---------------------------------------------------------------------------------------------------

    def run_once(self) -> dict:
        with self._lock:
            if self._running:
                return {"running": True}
            self._running = True
        counts: dict[str, int] = {}
        try:
            for path, asset_id in self._todo():
                if PRESSURE.busy:
                    counts["held (Immich busy)"] = counts.get("held (Immich busy)", 0) + 1
                    break
                try:
                    r = self.fix_one(path, asset_id)
                    if r in ("applied", "time_fixed") and PAUSE_S:
                        time.sleep(PAUSE_S)
                except Exception as ex:  # one bad file or a brief Immich error must not stop the pass; it is retried later
                    log.warning("auto-fix failed for %s: %s", os.path.basename(path), ex)
                    PRESSURE.report_error(ex)
                    self._save(asset_id, path, "review", f"could not be checked: {str(ex)[:120]}")
                    r = "error"
                counts[r] = counts.get(r, 0) + 1
            if not PRESSURE.busy:
                try:
                    for k, v in self.align_clocks().items():
                        counts[f"clock {k}"] = v
                except Exception as ex:  # noqa: BLE001
                    log.warning("camera clock check failed: %s", ex)
                    PRESSURE.report_error(ex)
        finally:
            self.last_run = time.time()
            with self._lock:
                self._running = False
        if counts:
            log.info("auto-fix pass: %s", json.dumps(counts, sort_keys=True))
        return counts

    def status_of(self, asset_id: str) -> str | None:
        with self._lock:
            row = self._db.execute("SELECT status FROM autofix WHERE asset_id=?", (asset_id,)).fetchone()
        return row[0] if row else None

    def describe(self, limit: int = 200) -> dict:
        with self._lock:
            counts = dict(self._db.execute("SELECT status,count(*) FROM autofix GROUP BY status").fetchall())
            reasons = dict(self._db.execute("SELECT reason,count(*) FROM autofix WHERE status='review' GROUP BY reason").fetchall())
            review = [{"asset": a, "name": os.path.basename(p), "reason": r} for a, p, r in self._db.execute(
                "SELECT asset_id,path,reason FROM autofix WHERE status='review' ORDER BY path LIMIT ?", (limit,))]
            applied = [{"asset": a, "name": os.path.basename(p), "lat": la, "lon": lo, "zone": z, "gap_s": g, "old_time": o, "new_time": n}
                       for a, p, la, lo, z, g, o, n in self._db.execute(
                           "SELECT asset_id,path,lat,lon,zone,gap_s,old_time,new_time FROM autofix WHERE status='applied' ORDER BY applied_at DESC LIMIT ?", (limit,))]
            clocks = [{"folder": os.path.basename(f), "camera": c, "status": s, "offset_s": o, "offset": describe_offset(o) if o is not None else "",
                       "zone": z, "pairs": n, "reason": r} for f, c, s, o, z, n, r in self._db.execute(
                           "SELECT folder,camera,status,offset_s,zone,pairs,reason FROM clocks ORDER BY checked_at DESC LIMIT ?", (limit,))]
            clock_counts = dict(self._db.execute("SELECT status,count(*) FROM clocks GROUP BY status").fetchall())
            running = self._running
        return {"running": running, "last_run": self.last_run, "counts": counts, "reasons": reasons, "review": review, "applied": applied,
                "clocks": clocks, "clock_counts": clock_counts}
