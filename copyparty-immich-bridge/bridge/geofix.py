"""Fix missing location / time zone BEFORE import ("Fix locations" tab).

Action cameras (GoPro, Insta360) usually write a local wall-clock time with no time zone and often no GPS, so
Immich files them under "missing time zone" and nowhere on the map. This module:

1. SCANS a folder with exiftool (the same tool Immich reads metadata with) for capture time, zone offset and GPS;
2. groups the files that lack them into SESSIONS (one folder, no gap longer than SESSION_GAP);
3. SUGGESTS a place + zone per session from the person's own Immich photos taken around the same time;
4. stores what the person ACCEPTS, and hands the import worker an XMP sidecar for those files.

Originals are never modified and nothing is written next to them: decisions live in the bridge's own database
and the sidecar is generated at upload time (Immich prefers a sidecar's date/zone and GPS over the file's own:
server/src/services/metadata.service.ts::getExifTags).

Matching trick for clocks without a zone: the camera's wall-clock time cannot be turned into an instant, but every
Immich neighbour has BOTH an instant and a local time. If the camera was set to local time where the neighbour was
taken, their wall-clock times are close - so neighbours are compared by local time, and the neighbour's own offset
becomes the suggested zone. No time-zone database is needed.
"""

from __future__ import annotations

import hashlib
import json
import logging
import math
import os
import re
import shutil
import sqlite3
import subprocess
import threading
import time
from collections import Counter
from datetime import datetime, timedelta, timezone
from typing import Callable
from xml.sax.saxutils import escape

from bridge.scanner import is_within_dirs

log = logging.getLogger("bridge.geofix")

SESSION_GAP = timedelta(hours=3)
CLUSTER_KM = 30.0
TIERS_HOURS = (12, 72, 336)  # how far (local wall-clock) to look for neighbours: widen only when empty
MAX_PAGES = 5
BATCH = 80
MAX_FILES = 50000
FILES_IN_PAYLOAD = 48
MARK = "copyparty-immich-bridge location fix"
EXIF_TAGS = ["-DateTimeOriginal", "-CreateDate", "-MediaCreateDate", "-OffsetTimeOriginal", "-OffsetTime",
             "-Composite:GPSLatitude", "-Composite:GPSLongitude", "-Make", "-Model"]
VIDEO_EXT = {"mp4", "mov", "insv", "lrv", "360", "m4v", "avi", "mts", "mkv"}
# Insta360 names carry the camera's wall clock: VID_20260501_142000_00_001.insv (LRV_/IMG_ too; _LL_ = lens/type).
# Its QuickTime CreateDate is that clock turned into UTC with the zone set IN THE CAMERA (seen on real files: hours off,
# not always the zone the camera was really in), so for a zone-less match the name is the trustworthy local clock.
INSTA360_NAME = re.compile(r"^(?:VID|LRV|IMG)_(\d{8}_\d{6})_\d{2}_\d{3}\.", re.I)
QUICKTIME_KEYS = ("CreateDate", "MediaCreateDate")
READER_VERSION = 2  # bump whenever a change to reading metadata must invalidate the cached files table


class GeoFixError(Exception):
    def __init__(self, message: str, code: int = 400):
        super().__init__(message)
        self.code = code


# -- small pure helpers --------------------------------------------------------------------------------------


def parse_exif_time(value) -> tuple[datetime | None, int | None]:
    """'2026:05:01 14:03:22[.12][+09:00|Z]' -> (naive local datetime, offset in minutes or None)."""
    if not isinstance(value, str) or len(value) < 19 or value.startswith("0000"):
        return None, None
    try:
        local = datetime.strptime(value[:19].replace("-", ":").replace("T", " "), "%Y:%m:%d %H:%M:%S")
    except ValueError:
        return None, None
    if local.year < 1990:
        return None, None
    rest = value[19:].lstrip(".0123456789")  # sub-seconds
    return local, parse_offset(rest)


def insta360_clock(path: str) -> datetime | None:
    """The camera's wall clock from an Insta360 file name, or None for any other name."""
    m = INSTA360_NAME.match(os.path.basename(path))
    if not m:
        return None
    try:
        return datetime.strptime(m.group(1), "%Y%m%d_%H%M%S")
    except ValueError:
        return None


def parse_offset(value) -> int | None:
    """'+09:00' / '-0330' / 'Z' -> minutes east of UTC."""
    if not isinstance(value, str):
        return None
    v = value.strip()
    if v in ("Z", "z"):
        return 0
    if len(v) < 3 or v[0] not in "+-":
        return None
    digits = v[1:].replace(":", "")
    if not digits.isdigit() or len(digits) not in (2, 4):
        return None
    minutes = int(digits[:2]) * 60 + (int(digits[2:]) if len(digits) == 4 else 0)
    if minutes > 14 * 60:
        return None
    return minutes if v[0] == "+" else -minutes


def fmt_offset(minutes: int) -> str:
    sign = "+" if minutes >= 0 else "-"
    m = abs(minutes)
    return f"{sign}{m // 60:02d}:{m % 60:02d}"


def haversine_km(a_lat: float, a_lon: float, b_lat: float, b_lon: float) -> float:
    p1, p2 = math.radians(a_lat), math.radians(b_lat)
    h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(b_lon - a_lon) / 2) ** 2
    return 6371.0 * 2 * math.asin(min(1.0, math.sqrt(h)))


def _xmp_coord(value: float, pos: str, neg: str) -> str:
    """XMP GPS form: 'DDD,MM.mmmmmmK' (what exiftool itself writes into XMP-exif)."""
    ref = pos if value >= 0 else neg
    v = abs(value)
    deg = int(v)
    return f"{deg},{(v - deg) * 60:.6f}{ref}"


def build_sidecar(taken: datetime | None, offset_min: int | None, lat: float | None, lon: float | None) -> bytes:
    """The XMP sidecar uploaded with a file. Same tags Immich writes itself when a location/date is edited
    (metadata.service.ts::handleSidecarWrite): DateTimeOriginal with its zone, GPSLatitude, GPSLongitude."""
    lines = []
    if taken is not None and offset_min is not None:
        stamp = taken.strftime("%Y-%m-%dT%H:%M:%S") + fmt_offset(offset_min)
        lines.append(f"   <exif:DateTimeOriginal>{stamp}</exif:DateTimeOriginal>")
        lines.append(f"   <photoshop:DateCreated>{stamp}</photoshop:DateCreated>")
    if lat is not None and lon is not None:
        lines.append(f"   <exif:GPSLatitude>{_xmp_coord(lat, 'N', 'S')}</exif:GPSLatitude>")
        lines.append(f"   <exif:GPSLongitude>{_xmp_coord(lon, 'E', 'W')}</exif:GPSLongitude>")
    body = "\n".join(lines)
    return (
        "<?xpacket begin='﻿' id='W5M0MpCehiHzreSzNTczkc9d'?>\n"
        f"<x:xmpmeta xmlns:x='adobe:ns:meta/' x:xmptk='{escape(MARK)}'>\n"
        " <rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>\n"
        "  <rdf:Description rdf:about=''\n"
        "    xmlns:exif='http://ns.adobe.com/exif/1.0/'\n"
        "    xmlns:photoshop='http://ns.adobe.com/photoshop/1.0/'>\n"
        f"{body}\n"
        "  </rdf:Description>\n"
        " </rdf:RDF>\n"
        "</x:xmpmeta>\n"
        "<?xpacket end='w'?>\n"
    ).encode("utf-8")


def _iso_utc(value) -> datetime | None:
    if not isinstance(value, str) or len(value) < 19:
        return None
    try:
        return datetime.strptime(value[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None


def neighbour_from_asset(asset: dict) -> dict | None:
    """An Immich asset that can vouch for a place: it has GPS, an instant and a local time."""
    exif = asset.get("exifInfo") or {}
    lat, lon = exif.get("latitude"), exif.get("longitude")
    if not isinstance(lat, (int, float)) or not isinstance(lon, (int, float)) or (lat == 0 and lon == 0):
        return None
    utc, local = _iso_utc(asset.get("fileCreatedAt")), _iso_utc(asset.get("localDateTime"))
    if utc is None or local is None:
        return None
    offset = int(round((local - utc).total_seconds() / 900.0)) * 15
    if abs(offset) > 14 * 60:
        return None
    return {"id": asset.get("id"), "utc": utc, "local": local, "offset": offset, "lat": float(lat), "lon": float(lon),
            "zone": exif.get("timeZone") or "", "city": exif.get("city") or "", "state": exif.get("state") or "",
            "country": exif.get("country") or ""}


def _gap(point: datetime, start: datetime, end: datetime) -> float:
    """Seconds between a moment and a time span (0 inside it)."""
    if point < start:
        return (start - point).total_seconds()
    if point > end:
        return (point - end).total_seconds()
    return 0.0


def rank_suggestions(start: datetime, end: datetime, known_offset: int | None, neighbours: list[dict], limit: int = 3) -> list[dict]:
    """Clusters neighbours by place and ranks the places. `start`/`end` are the session's local wall-clock span;
    with a known zone offset the comparison is by true instant instead."""
    scored = []
    for n in neighbours:
        if known_offset is not None:
            gap = _gap(n["utc"], start - timedelta(minutes=known_offset), end - timedelta(minutes=known_offset))
        else:
            gap = _gap(n["local"], start, end)
        scored.append((gap, n))
    scored.sort(key=lambda x: x[0])
    clusters: list[dict] = []
    for gap, n in scored:
        home = next((c for c in clusters if haversine_km(c["lat"], c["lon"], n["lat"], n["lon"]) <= CLUSTER_KM), None)
        if home is None:
            home = {"lat": n["lat"], "lon": n["lon"], "gap": gap, "members": []}  # seeded by its nearest-in-time photo
            clusters.append(home)
        home["members"].append((gap, n))
    near_total = sum(1 for gap, _ in scored if gap <= 12 * 3600) or 1
    out = []
    for c in clusters:
        members = c["members"]
        offsets = Counter(n["offset"] for _, n in members)
        offset = offsets.most_common(1)[0][0]
        zone = Counter(n["zone"] for _, n in members if n["zone"] and n["offset"] == offset).most_common(1)
        places = Counter((n["city"], n["state"], n["country"]) for _, n in members if n["city"] or n["country"]).most_common(1)
        city, state, country = places[0][0] if places else ("", "", "")
        label = ", ".join(x for x in (city, state if state and state != city else "", country) if x) or f"{c['lat']:.3f}, {c['lon']:.3f}"
        near = sum(1 for gap, _ in members if gap <= 12 * 3600)
        share = near / near_total
        if c["gap"] <= 2 * 3600 and len(members) >= 3 and share >= 0.8:
            confidence = "high"
        elif c["gap"] <= 12 * 3600:
            confidence = "medium"
        else:
            confidence = "low"
        out.append({"lat": round(c["lat"], 6), "lon": round(c["lon"], 6), "offset_min": offset, "zone": zone[0][0] if zone else "",
                    "label": label, "count": len(members), "gap_seconds": int(c["gap"]), "confidence": confidence,
                    "samples": [n["id"] for _, n in members[:3] if n["id"]]})
    order = {"high": 0, "medium": 1, "low": 2}
    out.sort(key=lambda s: (order[s["confidence"]], s["gap_seconds"] // 3600, -s["count"]))
    return out[:limit]


# -- the store + scanner -------------------------------------------------------------------------------------


class GeoFix:
    def __init__(self, db_path: str, browse_roots: Callable[[], list[str]], extensions: Callable[[], set[str]],
                 thumbs_dir: str | None = None, exiftool: str = "exiftool", ffmpeg: str = "ffmpeg"):
        self._lock = threading.RLock()
        self._roots = browse_roots
        self._extensions = extensions
        self._exiftool, self._ffmpeg = exiftool, ffmpeg
        self._thumbs = thumbs_dir or os.path.join(os.path.dirname(db_path) or ".", "geofix-thumbs")
        self._thumb_gate = threading.Semaphore(2)
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.executescript(
            """
            CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, size INTEGER, mtime REAL, taken TEXT, offset_min INTEGER,
                lat REAL, lon REAL, make TEXT, model TEXT);
            CREATE TABLE IF NOT EXISTS decisions (name TEXT, size INTEGER, path TEXT, status TEXT, lat REAL, lon REAL,
                offset_min INTEGER, taken TEXT, label TEXT, source TEXT, decided_at REAL, applied_at REAL, applied_note TEXT,
                PRIMARY KEY (name, size));
            """
        )
        # The files table is only a cache of what exiftool said. When the way files are READ changes, drop it so
        # a rescan reads every file again (0.3.0 cached "no time" for every GoPro/Insta360 video). Decisions stay.
        if self._db.execute("PRAGMA user_version").fetchone()[0] < READER_VERSION:
            self._db.execute("DELETE FROM files")
            self._db.execute(f"PRAGMA user_version = {READER_VERSION}")
        self._db.commit()
        self.status: dict = {"running": False, "phase": "", "done": 0, "total": 0, "error": "", "folder": "", "user": "", "finished_at": 0}
        self._files: list[dict] = []
        self._sessions: list[dict] = []
        self._tool_cache: tuple[float, dict] | None = None

    def close(self) -> None:
        with self._lock:
            self._db.close()

    # -- tools ------------------------------------------------------------------------------------------

    def tools(self) -> dict:
        now = time.time()
        if self._tool_cache and now - self._tool_cache[0] < 60:
            return self._tool_cache[1]
        version = ""
        try:
            version = subprocess.run([self._exiftool, "-ver"], capture_output=True, text=True, timeout=15).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            version = ""
        out = {"exiftool": version, "ffmpeg": bool(shutil.which(self._ffmpeg))}
        self._tool_cache = (now, out)
        return out

    # -- scanning ---------------------------------------------------------------------------------------

    def check_folder(self, folder: str) -> str:
        if not isinstance(folder, str) or not os.path.isabs(folder):
            raise GeoFixError("choose a folder first")
        real = os.path.realpath(folder)
        if not is_within_dirs(real, [os.path.realpath(r) for r in self._roots()]):
            raise GeoFixError("that folder is outside the folders this container can see", 403)
        if not os.path.isdir(real):
            raise GeoFixError("that folder does not exist (any more)", 404)
        return os.path.normpath(folder)

    def start_scan(self, folder: str, user: str, search: Callable[[dict], dict] | None) -> None:
        """`search(body)` = POST /search/metadata with the chosen person's key. Runs in the background."""
        folder = self.check_folder(folder)
        if not self.tools()["exiftool"]:
            raise GeoFixError("exiftool is not installed in the bridge container. Update the bridge "
                              "(update-bridge.sh rebuilds it with exiftool) and try again.", 503)
        with self._lock:
            if self.status["running"]:
                raise GeoFixError("a scan is already running", 409)
            self.status = {"running": True, "phase": "listing files", "done": 0, "total": 0, "error": "", "folder": folder,
                           "user": user, "finished_at": 0}
        threading.Thread(target=self._scan, args=(folder, search), name="geofix-scan", daemon=True).start()

    def _scan(self, folder: str, search) -> None:
        try:
            paths = self._list_media(folder)
            self._set(phase="reading capture time and GPS", total=len(paths), done=0)
            files = self._read_metadata(paths)
            sessions = self._make_sessions(files)
            todo = [s for s in sessions if s["need"]]
            self._set(phase="looking for nearby photos in Immich", total=len(todo), done=0)
            problem = ""
            for i, s in enumerate(todo):
                if search is not None and s["start"] is not None and not problem:
                    try:
                        s["suggestions"], s["searched_hours"] = self._suggest(s, search)
                    except Exception as ex:  # Immich down / key without asset.read: keep the scan, say why
                        problem = f"could not ask Immich for nearby photos: {ex}"
                        log.warning(problem)
                self._set(done=i + 1)
            with self._lock:
                self._files, self._sessions = files, sessions
            self._set(running=False, phase="done", error=problem, finished_at=time.time())
            log.info("location scan of %s: %d files, %d session(s) need a place", folder, len(files), len(todo))
        except Exception as ex:
            log.exception("location scan failed")
            self._set(running=False, phase="failed", error=str(ex), finished_at=time.time())

    def _set(self, **kw) -> None:
        with self._lock:
            self.status.update(kw)

    def _list_media(self, folder: str) -> list[str]:
        exts = self._extensions()
        out: list[str] = []
        for base, dirs, names in os.walk(folder, followlinks=False):
            dirs[:] = sorted(d for d in dirs if not d.startswith("."))
            for name in sorted(names):
                if name.startswith(".") or name.rsplit(".", 1)[-1].lower() not in exts:
                    continue
                full = os.path.join(base, name)
                if os.path.islink(full):
                    continue
                out.append(full)
                if len(out) >= MAX_FILES:
                    return out
        return out

    def _read_metadata(self, paths: list[str]) -> list[dict]:
        files: list[dict] = []
        pending: list[tuple[str, int, float]] = []
        with self._lock:
            cached = {r[0]: r for r in self._db.execute("SELECT path,size,mtime,taken,offset_min,lat,lon,make,model FROM files")}
        for p in paths:
            try:
                st = os.stat(p)
            except OSError:
                continue
            row = cached.get(p)
            if row and row[1] == st.st_size and abs(row[2] - st.st_mtime) < 1:
                files.append(self._file(p, st.st_size, st.st_mtime, row[3], row[4], row[5], row[6], row[7], row[8]))
            else:
                pending.append((p, st.st_size, st.st_mtime))
        self._set(done=len(files))
        for i in range(0, len(pending), BATCH):
            chunk = pending[i : i + BATCH]
            tags = self._exiftool_json([p for p, _, _ in chunk])
            rows = []
            for p, size, mtime in chunk:
                t = tags.get(p) or {}
                taken, offset, key = None, None, None
                for key in ("DateTimeOriginal", *QUICKTIME_KEYS):
                    taken, offset = parse_exif_time(t.get(key))
                    if taken is not None:
                        break
                if key in QUICKTIME_KEYS and offset is None:
                    taken = insta360_clock(p) or taken
                if offset is None:
                    offset = parse_offset(t.get("OffsetTimeOriginal"))
                if offset is None:
                    offset = parse_offset(t.get("OffsetTime"))
                lat, lon = t.get("GPSLatitude"), t.get("GPSLongitude")
                if not isinstance(lat, (int, float)) or not isinstance(lon, (int, float)) or (lat == 0 and lon == 0):
                    lat = lon = None
                taken_s = taken.isoformat() if taken else None
                rows.append((p, size, mtime, taken_s, offset, lat, lon, str(t.get("Make") or ""), str(t.get("Model") or "")))
                files.append(self._file(*rows[-1]))
            with self._lock:
                self._db.executemany("INSERT OR REPLACE INTO files VALUES (?,?,?,?,?,?,?,?,?)", rows)
                self._db.commit()
            self._set(done=len(files))
        files.sort(key=lambda f: f["path"])
        return files

    @staticmethod
    def _file(path, size, mtime, taken, offset, lat, lon, make, model) -> dict:
        return {"path": path, "name": os.path.basename(path), "folder": os.path.dirname(path), "size": size, "mtime": mtime,
                "taken": datetime.fromisoformat(taken) if taken else None, "offset_min": offset, "lat": lat, "lon": lon,
                "camera": " ".join(x for x in (make, model) if x).strip(),
                "video": path.rsplit(".", 1)[-1].lower() in VIDEO_EXT,
                # GPS present = Immich works the zone out itself; a zone but no GPS = only the place is missing
                "need": "" if lat is not None else ("place" if offset is not None else "place and time zone")}

    def _exiftool_json(self, paths: list[str]) -> dict[str, dict]:
        cmd = [self._exiftool, "-json", "-n", "-charset", "filename=utf8", *EXIF_TAGS, "--", *paths]
        try:
            proc = subprocess.run(cmd, capture_output=True, timeout=600)
        except subprocess.TimeoutExpired as ex:
            raise GeoFixError("exiftool took too long on a batch of files") from ex
        try:
            rows = json.loads(proc.stdout.decode("utf-8", "replace") or "[]")
        except json.JSONDecodeError as ex:
            raise GeoFixError(f"exiftool gave no usable answer: {proc.stderr.decode('utf-8', 'replace')[:200]}") from ex
        return {r.get("SourceFile"): r for r in rows if isinstance(r, dict)}

    def _make_sessions(self, files: list[dict]) -> list[dict]:
        by_folder: dict[str, list[dict]] = {}
        for f in files:
            by_folder.setdefault(f["folder"], []).append(f)
        sessions = []
        for folder, items in sorted(by_folder.items()):
            dated = sorted((f for f in items if f["taken"]), key=lambda f: f["taken"])
            groups: list[list[dict]] = []
            for f in dated:
                if groups and f["taken"] - groups[-1][-1]["taken"] <= SESSION_GAP:
                    groups[-1].append(f)
                else:
                    groups.append([f])
            undated = [f for f in items if not f["taken"]]
            if undated:
                groups.append(undated)
            for g in groups:
                need = [f for f in g if f["need"]]
                offsets = {f["offset_min"] for f in need}
                start = g[0]["taken"]
                key = f"{folder}|{start.isoformat() if start else 'undated'}"
                sessions.append({"id": hashlib.sha1(key.encode()).hexdigest()[:12], "folder": folder, "files": g,
                                 "start": start, "end": g[-1]["taken"], "need": need,
                                 "known_offset": offsets.pop() if len(offsets) == 1 and None not in offsets else None,
                                 "suggestions": [], "searched_hours": 0})
        return sessions

    def _suggest(self, session: dict, search) -> tuple[list[dict], int]:
        need = session["need"]
        start, end = need[0]["taken"], need[-1]["taken"]
        known = session["known_offset"]
        for hours in TIERS_HOURS:
            reach = timedelta(hours=hours)
            if known is None:  # the camera's zone is anything from UTC-12 to UTC+14
                after, before = start - reach - timedelta(hours=14), end + reach + timedelta(hours=12)
            else:
                after, before = start - reach - timedelta(minutes=known), end + reach - timedelta(minutes=known)
            neighbours: list[dict] = []
            page = 1
            for _ in range(MAX_PAGES):
                body = {"takenAfter": after.strftime("%Y-%m-%dT%H:%M:%S.000Z"), "takenBefore": before.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                        "withExif": True, "size": 1000, "page": page}
                assets = ((search(body) or {}).get("assets") or {})
                for a in assets.get("items") or []:
                    n = neighbour_from_asset(a)
                    if n is None:
                        continue
                    gap = _gap(n["utc"], start - timedelta(minutes=known), end - timedelta(minutes=known)) if known is not None else _gap(n["local"], start, end)
                    if gap <= reach.total_seconds():
                        neighbours.append(n)
                nxt = assets.get("nextPage")
                if not nxt:
                    break
                page = int(nxt)
            if neighbours:
                return rank_suggestions(start, end, known, neighbours), hours
        return [], TIERS_HOURS[-1]

    # -- decisions --------------------------------------------------------------------------------------

    def _decision_rows(self) -> dict[tuple[str, int], dict]:
        cols = ("name", "size", "path", "status", "lat", "lon", "offset_min", "taken", "label", "source", "decided_at", "applied_at", "applied_note")
        with self._lock:
            return {(r[0], r[1]): dict(zip(cols, r)) for r in self._db.execute(f"SELECT {','.join(cols)} FROM decisions")}

    def _session(self, sid: str) -> dict:
        with self._lock:
            s = next((x for x in self._sessions if x["id"] == sid), None)
        if s is None:
            raise GeoFixError("that group is not in the current scan any more - scan again", 404)
        return s

    def decide(self, sid: str, action: str, suggestion: int | None = None, custom: dict | None = None) -> None:
        s = self._session(sid)
        now = time.time()
        if action == "clear":
            with self._lock:
                self._db.executemany("DELETE FROM decisions WHERE name=? AND size=? AND applied_at IS NULL", [(f["name"], f["size"]) for f in s["need"]])
                self._db.commit()
            return
        if action == "skip":
            rows = [(f["name"], f["size"], f["path"], "skipped", None, None, None, None, "", "", now, None, None) for f in s["need"]]
        elif action == "accept":
            if custom is not None:
                lat, lon, offset, label, source = self._check_custom(custom)
            else:
                if not isinstance(suggestion, int) or isinstance(suggestion, bool) or not 0 <= suggestion < len(s["suggestions"]):
                    raise GeoFixError("pick one of the suggested places")
                pick = s["suggestions"][suggestion]
                lat, lon, offset, label, source = pick["lat"], pick["lon"], pick["offset_min"], pick["label"], f"immich neighbours ({pick['confidence']})"
            rows = []
            for f in s["need"]:
                if f["offset_min"] is not None:  # the file knows its zone: only the place is added
                    rows.append((f["name"], f["size"], f["path"], "accepted", lat, lon, None, None, label, source, now, None, None))
                elif f["taken"] is None or offset is None:  # no clock to correct (or 'let Immich work it out')
                    rows.append((f["name"], f["size"], f["path"], "accepted", lat, lon, None, None, label, source, now, None, None))
                else:
                    rows.append((f["name"], f["size"], f["path"], "accepted", lat, lon, offset, f["taken"].isoformat(), label, source, now, None, None))
        else:
            raise GeoFixError("unknown action")
        with self._lock:
            self._db.executemany("INSERT OR REPLACE INTO decisions VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
            self._db.commit()

    @staticmethod
    def _check_custom(c: dict) -> tuple[float, float, int | None, str, str]:
        lat, lon, offset = c.get("lat"), c.get("lon"), c.get("offset_min")
        ok = all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in (lat, lon))
        if not ok or not -90 <= lat <= 90 or not -180 <= lon <= 180:
            raise GeoFixError("latitude must be -90..90 and longitude -180..180")
        if offset is not None and (not isinstance(offset, int) or isinstance(offset, bool) or abs(offset) > 14 * 60 or offset % 15):
            raise GeoFixError("the time zone offset must be a quarter-hour step between -12:00 and +14:00")
        label = " ".join(str(c.get("label") or "").split())[:120] or f"{lat:.4f}, {lon:.4f}"
        return float(lat), float(lon), offset, label, "chosen by hand"

    def accept_confident(self) -> int:
        """Accepts the top suggestion of every undecided group whose top suggestion is 'high'."""
        decided = self._decision_rows()
        with self._lock:
            sessions = list(self._sessions)
        n = 0
        for s in sessions:
            if not s["need"] or not s["suggestions"] or s["suggestions"][0]["confidence"] != "high":
                continue
            if any((f["name"], f["size"]) in decided for f in s["need"]):
                continue
            self.decide(s["id"], "accept", 0)
            n += 1
        return n

    # -- what the import worker asks ----------------------------------------------------------------------

    def sidecar_for(self, path: str) -> bytes | None:
        """The sidecar to upload with this file, or None. Follows the file when its folder was moved (name + size)."""
        try:
            size = os.path.getsize(path)
        except OSError:
            return None
        with self._lock:
            row = self._db.execute("SELECT lat,lon,offset_min,taken FROM decisions WHERE name=? AND size=? AND status='accepted'",
                                   (os.path.basename(path), size)).fetchone()
        if row is None or row[0] is None:
            return None
        taken = datetime.fromisoformat(row[3]) if row[3] else None
        return build_sidecar(taken, row[2], row[0], row[1])

    def mark_applied(self, path: str, note: str) -> None:
        try:
            size = os.path.getsize(path)
        except OSError:
            return
        with self._lock:
            self._db.execute("UPDATE decisions SET applied_at=?, applied_note=? WHERE name=? AND size=?", (time.time(), note, os.path.basename(path), size))
            self._db.commit()

    # -- web page ---------------------------------------------------------------------------------------

    def describe(self) -> dict:
        decided = self._decision_rows()
        with self._lock:
            status, files, sessions = dict(self.status), list(self._files), list(self._sessions)
        out = []
        for s in sessions:
            if not s["need"]:
                continue
            rows = [decided.get((f["name"], f["size"])) for f in s["need"]]
            states = Counter((r or {}).get("status", "open") for r in rows)
            first = next((r for r in rows if r), None)
            decision = None
            if first is not None:
                applied = sum(1 for r in rows if r and r["applied_at"])
                notes = Counter(r["applied_note"] for r in rows if r and r["applied_note"])
                decision = {"status": first["status"], "label": first["label"], "lat": first["lat"], "lon": first["lon"],
                            "offset_min": first["offset_min"], "source": first["source"], "applied": applied, "notes": dict(notes)}
            f0 = s["need"][0]
            example = None
            off = decision["offset_min"] if decision and decision["status"] == "accepted" else None
            if off is not None and f0["taken"] is not None:
                example = {"name": f0["name"], "local": f0["taken"].strftime("%Y-%m-%d %H:%M"), "offset": fmt_offset(off),
                           "utc": (f0["taken"] - timedelta(minutes=off)).strftime("%Y-%m-%d %H:%M")}
            out.append({
                "id": s["id"], "folder": s["folder"], "start": s["start"].isoformat() if s["start"] else None,
                "end": s["end"].isoformat() if s["end"] else None, "count": len(s["files"]), "need_count": len(s["need"]),
                "needs": dict(Counter(f["need"] for f in s["need"])), "cameras": sorted({f["camera"] for f in s["need"] if f["camera"]}),
                "videos": sum(1 for f in s["need"] if f["video"]),
                "files": [{"path": f["path"], "name": f["name"], "video": f["video"], "taken": f["taken"].isoformat() if f["taken"] else None}
                          for f in s["need"][:FILES_IN_PAYLOAD]],
                "suggestions": s["suggestions"], "searched_hours": s["searched_hours"], "states": dict(states),
                "decision": decision, "example": example,
            })
        need = sum(len(s["need"]) for s in sessions)
        summary = {"files": len(files), "fine": len(files) - need, "need": need,
                   "accepted": sum(s["states"].get("accepted", 0) for s in out),
                   "skipped": sum(s["states"].get("skipped", 0) for s in out),
                   "open": sum(s["states"].get("open", 0) for s in out),
                   "confident": sum(1 for s in out if s["states"].get("open") == s["need_count"] and s["suggestions"] and s["suggestions"][0]["confidence"] == "high")}
        return {"tools": self.tools(), "status": status, "summary": summary, "sessions": out}

    def preview_sidecar(self, path: str) -> bytes:
        data = self.sidecar_for(path)
        if data is None:
            raise GeoFixError("no accepted place for that file", 404)
        return data

    # -- thumbnails -------------------------------------------------------------------------------------

    def thumbnail(self, path: str) -> bytes:
        with self._lock:
            known = any(f["path"] == path for f in self._files)
        if not known:  # only files of the current scan: this is not a general file server
            raise GeoFixError("not a file of the current scan", 404)
        try:
            st = os.stat(path)
        except OSError as ex:
            raise GeoFixError("file is gone", 404) from ex
        os.makedirs(self._thumbs, mode=0o700, exist_ok=True)
        cache = os.path.join(self._thumbs, hashlib.sha1(f"{path}|{st.st_size}|{st.st_mtime}".encode()).hexdigest() + ".jpg")
        if os.path.isfile(cache) and os.path.getsize(cache) > 0:
            with open(cache, "rb") as fh:
                return fh.read()
        stem = os.path.splitext(path)[0]
        source, video = path, path.rsplit(".", 1)[-1].lower() in VIDEO_EXT
        for thm in (stem + ".THM", stem + ".thm"):  # older GoPros leave a ready-made thumbnail next to each video
            if os.path.isfile(thm):
                source, video = thm, False
                break
        if not shutil.which(self._ffmpeg):
            raise GeoFixError("no preview (ffmpeg is not installed in the bridge container)", 404)
        tmp = cache + f".{threading.get_ident()}.tmp.jpg"
        cmd = [self._ffmpeg, "-nostdin", "-loglevel", "error", "-y"] + (["-ss", "1"] if video else []) + \
              ["-i", source, "-frames:v", "1", "-vf", "scale=320:-2", "-q:v", "6", tmp]
        with self._thumb_gate:
            try:
                proc = subprocess.run(cmd, capture_output=True, timeout=45)
                if video and (proc.returncode != 0 or not os.path.isfile(tmp) or os.path.getsize(tmp) == 0):
                    cmd.remove("-ss"), cmd.remove("1")  # shorter than a second
                    proc = subprocess.run(cmd, capture_output=True, timeout=45)
            except (OSError, subprocess.SubprocessError) as ex:
                raise GeoFixError("no preview for this file", 404) from ex
        if proc.returncode != 0 or not os.path.isfile(tmp) or os.path.getsize(tmp) == 0:
            if os.path.exists(tmp):
                os.remove(tmp)
            raise GeoFixError("no preview for this file", 404)
        os.replace(tmp, cache)
        with open(cache, "rb") as fh:
            return fh.read()
