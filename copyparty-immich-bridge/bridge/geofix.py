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
from statistics import median
from datetime import datetime, timedelta, timezone
from typing import Callable
from xml.sax.saxutils import escape
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import requests

try:  # offline coordinates -> IANA time zone name (America/Los_Angeles); without it only offsets are shown
    from tzfpy import get_tz as _tz_at
except ImportError:  # pragma: no cover - the container installs it
    _tz_at = None

from bridge.immich import ImmichError
from bridge.scanner import is_within_dirs

log = logging.getLogger("bridge.geofix")

SESSION_GAP = timedelta(hours=3)
CLUSTER_KM = 30.0
TIERS_HOURS = (12, 72, 336)  # how far (local wall-clock) to look for neighbours: widen only when empty
MAX_PAGES = 5
BATCH = 80
ORIGINAL_MAX_BYTES = 4 << 30  # a missing Immich preview is made from the original; never download more than this
MAX_FILES = 50000
FILES_IN_PAYLOAD = 48
SPOT_M = 150  # photos within this distance of the nearest-in-time one are candidates for the "exact spot" level
CORE_M = 40  # the exact spot is the densest knot of those: the photo with most others within this distance
TIGHT_M = 60  # the exact spot is the default only when its photos lie within this radius and are at least half
#               of the nearby ones (else the town is)
SAVED_RADIUS_M = 150  # a saved place names any spot within this distance
# Street names for an exact spot not covered by a saved place: OpenStreetMap's public reverse geocoder (sends only
# that spot's coordinates; cached; at most 1 request a second per its usage policy). GEOFIX_REVERSE_GEOCODE=off
# switches it off.
NOMINATIM_URL = "https://nominatim.openstreetmap.org/reverse"
REVERSE_GEOCODE = os.environ.get("GEOFIX_REVERSE_GEOCODE", "osm").strip().lower() not in ("off", "0", "no", "false", "none")
MARK = "copyparty-immich-bridge location fix"
EXIF_TAGS = ["-DateTimeOriginal", "-CreateDate", "-MediaCreateDate", "-OffsetTimeOriginal", "-OffsetTime",
             "-Composite:GPSLatitude", "-Composite:GPSLongitude", "-Make", "-Model"]
VIDEO_EXT = {"mp4", "mov", "insv", "lrv", "360", "m4v", "avi", "mts", "mkv"}
# Insta360 names carry the camera's wall clock: VID_20260501_142000_00_001.insv (LRV_/IMG_ too; _LL_ = lens/type).
# Its QuickTime CreateDate is that clock turned into UTC with the zone set IN THE CAMERA (seen on real files: hours off,
# not always the zone the camera was really in), so for a zone-less match the name is the trustworthy local clock.
INSTA360_NAME = re.compile(r"^(?:VID|LRV|IMG)_(\d{8}_\d{6})_\d{2}_\d{3}\.", re.I)
QUICKTIME_KEYS = ("CreateDate", "MediaCreateDate")
READER_VERSION = 3  # bump whenever a change to reading metadata must invalidate the cached files table


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


def zone_at(lat: float, lon: float) -> str:
    """IANA time zone at a point ('America/Los_Angeles'), or '' when unknown."""
    if _tz_at is None:
        return ""
    try:
        name = _tz_at(lon, lat) or ""
        ZoneInfo(name)
        return name
    except (ValueError, ZoneInfoNotFoundError, OSError):
        return ""


def zone_offset(name: str, local: datetime) -> tuple[int | None, str]:
    """(minutes east of UTC, abbreviation like 'PDT') of a zone at a wall-clock time, daylight saving included."""
    if not name:
        return None, ""
    try:
        z = ZoneInfo(name)
    except (ValueError, ZoneInfoNotFoundError, OSError):
        return None, ""
    off = z.utcoffset(local)
    return (int(off.total_seconds() // 60) if off is not None else None), (z.tzname(local) or "")


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
        # exact spot: among the photos within SPOT_M of the nearest-in-time one, the densest knot (a walk around the
        # block must not pull the spot into a neighbour's garden: seen on real data, a 6-photo median 165 m off home)
        seed = members[0][1]
        near = [n for _, n in members if haversine_km(seed["lat"], seed["lon"], n["lat"], n["lon"]) * 1000 <= SPOT_M]
        knots = [[m for m in near if haversine_km(n["lat"], n["lon"], m["lat"], m["lon"]) * 1000 <= CORE_M] for n in near]
        spot = max(knots, key=len)
        s_lat, s_lon = median(n["lat"] for n in spot), median(n["lon"] for n in spot)
        radius = max(25, round(max(haversine_km(s_lat, s_lon, n["lat"], n["lon"]) for n in spot) * 1000))
        in_city = [n for _, n in members if (n["city"], n["state"], n["country"]) == (city, state, country)] or [n for _, n in members]
        out.append({"lat": round(c["lat"], 6), "lon": round(c["lon"], 6), "offset_min": offset, "zone": zone[0][0] if zone else "",
                    "label": label, "count": len(members), "gap_seconds": int(c["gap"]), "confidence": confidence,
                    "samples": [n["id"] for _, n in members[:3] if n["id"]],
                    "evidence": [{"id": n["id"], "local": n["local"].strftime("%Y-%m-%d %H:%M"), "place": n["city"] or n["country"]}
                                 for _, n in members[:3] if n["id"]],
                    "spot": {"lat": round(s_lat, 6), "lon": round(s_lon, 6), "radius_m": radius, "photos": len(spot), "nearby": len(near)},
                    "area": {"lat": round(sum(n["lat"] for n in in_city) / len(in_city), 6),
                             "lon": round(sum(n["lon"] for n in in_city) / len(in_city), 6), "city": city, "state": state, "country": country}})
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
        # The files table is only a cache of what exiftool said. When the way files are READ changes, drop it so
        # a rescan reads every file again (0.3.0 cached "no time" for every GoPro/Insta360 video). Decisions stay.
        stale = self._db.execute("PRAGMA user_version").fetchone()[0] < READER_VERSION
        if stale:
            self._db.execute("DROP TABLE IF EXISTS files")
        self._db.executescript(
            """
            CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, size INTEGER, mtime REAL, taken TEXT, offset_min INTEGER,
                lat REAL, lon REAL, make TEXT, model TEXT, clock_raw TEXT);
            CREATE TABLE IF NOT EXISTS places (id INTEGER PRIMARY KEY, name TEXT, lat REAL, lon REAL, radius_m INTEGER);
            CREATE TABLE IF NOT EXISTS street_names (key TEXT PRIMARY KEY, label TEXT, at REAL);
            CREATE TABLE IF NOT EXISTS decisions (name TEXT, size INTEGER, path TEXT, status TEXT, lat REAL, lon REAL,
                offset_min INTEGER, taken TEXT, label TEXT, source TEXT, decided_at REAL, applied_at REAL, applied_note TEXT,
                PRIMARY KEY (name, size));
            """
        )
        if "zone" not in [r[1] for r in self._db.execute("PRAGMA table_info(decisions)")]:
            self._db.execute("ALTER TABLE decisions ADD COLUMN zone TEXT")
        if stale:
            self._db.execute(f"PRAGMA user_version = {READER_VERSION}")
        self._db.commit()
        self._osm_lock, self._osm_last = threading.Lock(), 0.0
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

    def start_scan(self, folder: str, user: str, search: Callable[[dict], dict] | None,
                   places: Callable[[str], list[dict]] | None = None) -> None:
        """`search(body)` = POST /search/metadata with the chosen person's key; `places(name)` = Immich's place index
        (GET /search/places), used for the town-level choice. Runs in the background."""
        folder = self.check_folder(folder)
        if not self.tools()["exiftool"]:
            raise GeoFixError("exiftool is not installed in the bridge container. Update the bridge "
                              "(update-bridge.sh rebuilds it with exiftool) and try again.", 503)
        with self._lock:
            if self.status["running"]:
                raise GeoFixError("a scan is already running", 409)
            self.status = {"running": True, "phase": "listing files", "done": 0, "total": 0, "error": "", "folder": folder,
                           "user": user, "finished_at": 0}
        threading.Thread(target=self._scan, args=(folder, search, places), name="geofix-scan", daemon=True).start()

    def _scan(self, folder: str, search, places=None) -> None:
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
                        for g in s["suggestions"]:
                            self._add_levels(g, s, places)
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
            cached = {r[0]: r for r in self._db.execute("SELECT path,size,mtime,taken,offset_min,lat,lon,make,model,clock_raw FROM files")}
        for p in paths:
            try:
                st = os.stat(p)
            except OSError:
                continue
            row = cached.get(p)
            if row and row[1] == st.st_size and abs(row[2] - st.st_mtime) < 1:
                files.append(self._file(p, st.st_size, st.st_mtime, *row[3:10]))
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
                raw = str(t.get(key) or "") if taken is not None else ""  # what Immich itself will read
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
                rows.append((p, size, mtime, taken_s, offset, lat, lon, str(t.get("Make") or ""), str(t.get("Model") or ""), raw))
                files.append(self._file(*rows[-1]))
            with self._lock:
                self._db.executemany("INSERT OR REPLACE INTO files VALUES (?,?,?,?,?,?,?,?,?,?)", rows)
                self._db.commit()
            self._set(done=len(files))
        files.sort(key=lambda f: f["path"])
        return files

    @staticmethod
    def _file(path, size, mtime, taken, offset, lat, lon, make, model, raw="") -> dict:
        return {"path": path, "clock_raw": raw or "", "name": os.path.basename(path), "folder": os.path.dirname(path), "size": size, "mtime": mtime,
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

    def _add_levels(self, g: dict, session: dict, places) -> None:
        """Two ways to place a group: the exact spot of the photos (street name from a saved place or OpenStreetMap)
        and the town (Immich's own place index, else the middle of those photos). The default is the exact spot
        only when the suggestion is confident. Each level carries its IANA time zone (daylight saving per file)."""
        spot, area = g["spot"], g["area"]
        town = ", ".join(x for x in (area["city"], area["state"] if area["state"] != area["city"] else "", area["country"]) if x)
        t_lat, t_lon = area["lat"], area["lon"]
        if places is not None and area["city"]:
            try:
                hits = [p for p in places(area["city"]) or [] if isinstance(p, dict) and isinstance(p.get("latitude"), (int, float))
                        and str(p.get("name") or "").lower() == area["city"].lower()]
                best = min(hits, key=lambda p: haversine_km(spot["lat"], spot["lon"], p["latitude"], p["longitude"]), default=None)
                if best is not None and haversine_km(spot["lat"], spot["lon"], best["latitude"], best["longitude"]) <= CLUSTER_KM:
                    t_lat, t_lon = float(best["latitude"]), float(best["longitude"])
            except Exception as ex:  # the town level then uses the middle of the photos
                log.info("place lookup for %s failed: %s", area["city"], ex)
        g["levels"] = [
            {"kind": "spot", "lat": spot["lat"], "lon": spot["lon"], "radius_m": spot["radius_m"], "photos": spot["photos"],
             "street": self._street_name(spot["lat"], spot["lon"])},
            {"kind": "town", "lat": round(t_lat, 6), "lon": round(t_lon, 6), "label": town or g["label"]},
        ]
        tight = spot["radius_m"] <= TIGHT_M and spot["photos"] >= max(2, (spot.get("nearby") or 0) / 2)
        g["default_level"] = 0 if g["confidence"] == "high" and tight else 1
        start = session["need"][0]["taken"]
        for lv in g["levels"]:
            lv["zone"] = zone_at(lv["lat"], lv["lon"])
            off, abbr = zone_offset(lv["zone"], start) if start else (None, "")
            lv["offset_min"], lv["abbr"] = (off, abbr) if off is not None else (g["offset_min"], "")
        g["lat"], g["lon"] = g["levels"][g["default_level"]]["lat"], g["levels"][g["default_level"]]["lon"]

    def _street_name(self, lat: float, lon: float) -> str:
        """'470 Example Drive' for a spot, from OpenStreetMap (cached per ~10 m); '' when off, unknown or offline."""
        key = f"{lat:.4f},{lon:.4f}"
        with self._lock:
            row = self._db.execute("SELECT label FROM street_names WHERE key=?", (key,)).fetchone()
        if row is not None:
            return row[0]
        if not REVERSE_GEOCODE:
            return ""
        with self._osm_lock:  # their usage policy: at most one request a second, a real User-Agent
            time.sleep(max(0.0, 1.0 - (time.time() - self._osm_last)))
            try:
                from bridge import __version__
                resp = requests.get(NOMINATIM_URL, params={"lat": f"{lat:.6f}", "lon": f"{lon:.6f}", "format": "jsonv2", "zoom": 18,
                                                           "addressdetails": 1}, timeout=10,
                                    headers={"User-Agent": f"copyparty-immich-bridge/{__version__} (Fix locations)"})
                data = resp.json() if resp.status_code == 200 else {}
            except (requests.RequestException, ValueError) as ex:
                log.info("street name lookup failed: %s", ex)
                return ""
            finally:
                self._osm_last = time.time()
        a = data.get("address") or {}
        road = a.get("road") or a.get("pedestrian") or a.get("footway") or a.get("path") or ""
        label = " ".join(x for x in (a.get("house_number") or "", road) if x) or str(data.get("name") or "")
        if not label and data.get("display_name"):
            label = str(data["display_name"]).split(",")[0].strip()
        with self._lock:
            self._db.execute("INSERT OR REPLACE INTO street_names VALUES (?,?,?)", (key, label[:120], time.time()))
            self._db.commit()
        return label[:120]

    def saved_places(self) -> list[dict]:
        with self._lock:
            return [{"id": r[0], "name": r[1], "lat": r[2], "lon": r[3], "radius_m": r[4]}
                    for r in self._db.execute("SELECT id,name,lat,lon,radius_m FROM places ORDER BY name")]

    def save_place(self, name, lat, lon, radius_m=None) -> dict:
        name = " ".join(str(name or "").split())[:80]
        if not name:
            raise GeoFixError("give the place a name")
        if not all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in (lat, lon)) or not -90 <= lat <= 90 or not -180 <= lon <= 180:
            raise GeoFixError("latitude must be -90..90 and longitude -180..180")
        r = radius_m if isinstance(radius_m, int) and not isinstance(radius_m, bool) and 20 <= radius_m <= 5000 else SAVED_RADIUS_M
        with self._lock:
            cur = self._db.execute("INSERT INTO places (name,lat,lon,radius_m) VALUES (?,?,?,?)", (name, float(lat), float(lon), r))
            self._db.commit()
            return {"id": cur.lastrowid, "name": name, "lat": float(lat), "lon": float(lon), "radius_m": r}

    def delete_place(self, place_id) -> None:
        if not isinstance(place_id, int) or isinstance(place_id, bool):
            raise GeoFixError("no such saved place")
        with self._lock:
            self._db.execute("DELETE FROM places WHERE id=?", (place_id,))
            self._db.commit()

    @staticmethod
    def _saved_name(saved: list[dict], lat: float, lon: float) -> str:
        near = [(haversine_km(lat, lon, p["lat"], p["lon"]) * 1000, p) for p in saved]
        near = [(d, p) for d, p in near if d <= p["radius_m"]]
        return min(near, key=lambda x: x[0])[1]["name"] if near else ""

    def _level_view(self, lv: dict, saved: list[dict]) -> dict:
        out = dict(lv)
        if lv["kind"] == "spot":
            name = self._saved_name(saved, lv["lat"], lv["lon"])
            out["saved"] = bool(name)
            out["label"] = name or lv.get("street") or "Exact spot of your photos"
            out["detail"] = (f"±{lv['radius_m']} m · where {lv['photos']} of your photo{'s' if lv['photos'] != 1 else ''} were taken"
                             + ("" if name else (" · street name from OpenStreetMap" if lv.get("street") else "")))
        return out

    # -- decisions --------------------------------------------------------------------------------------

    def _decision_rows(self) -> dict[tuple[str, int], dict]:
        cols = ("name", "size", "path", "status", "lat", "lon", "offset_min", "taken", "label", "source", "decided_at", "applied_at", "applied_note", "zone")
        with self._lock:
            return {(r[0], r[1]): dict(zip(cols, r)) for r in self._db.execute(f"SELECT {','.join(cols)} FROM decisions")}

    def _session(self, sid: str) -> dict:
        with self._lock:
            s = next((x for x in self._sessions if x["id"] == sid), None)
        if s is None:
            raise GeoFixError("that group is not in the current scan any more - scan again", 404)
        return s

    def decide(self, sid: str, action: str, suggestion: int | None = None, custom: dict | None = None, level: int | None = None) -> None:
        s = self._session(sid)
        now = time.time()
        if action == "clear":
            with self._lock:
                self._db.executemany("DELETE FROM decisions WHERE name=? AND size=? AND applied_at IS NULL", [(f["name"], f["size"]) for f in s["need"]])
                self._db.commit()
            return
        if action == "skip":
            rows = [(f["name"], f["size"], f["path"], "skipped", None, None, None, None, "", "", now, None, None, "") for f in s["need"]]
        elif action == "accept":
            zone = ""
            if custom is not None:
                lat, lon, offset, label, source = self._check_custom(custom)
                zone = zone_at(lat, lon) if offset is None and custom.get("zone_from_place") else ""
            else:
                if not isinstance(suggestion, int) or isinstance(suggestion, bool) or not 0 <= suggestion < len(s["suggestions"]):
                    raise GeoFixError("pick one of the suggested places")
                pick = s["suggestions"][suggestion]
                lat, lon, offset, label, source = pick["lat"], pick["lon"], pick["offset_min"], pick["label"], f"immich neighbours ({pick['confidence']})"
                levels = pick.get("levels") or []
                if levels:
                    li = pick.get("default_level", 0) if level is None else level
                    if not isinstance(li, int) or isinstance(li, bool) or not 0 <= li < len(levels):
                        raise GeoFixError("pick the exact spot or the town")
                    lv = self._level_view(levels[li], self.saved_places())
                    lat, lon, zone = lv["lat"], lv["lon"], lv["zone"]
                    label = lv["label"] + ("" if lv["kind"] == "town" else f", {levels[1]['label']}" if len(levels) > 1 else "")
                    source += f", {'exact spot' if lv['kind'] == 'spot' else 'town'}"
            rows = []
            for f in s["need"]:
                if f["offset_min"] is not None:  # the file knows its zone: only the place is added
                    rows.append((f["name"], f["size"], f["path"], "accepted", lat, lon, None, None, label, source, now, None, None, zone))
                elif f["taken"] is None or (offset is None and not zone):  # no clock to correct (or 'let Immich work it out')
                    rows.append((f["name"], f["size"], f["path"], "accepted", lat, lon, None, None, label, source, now, None, None, zone))
                else:  # the zone's own offset at THIS file's time (daylight saving), else the neighbours' offset
                    off = zone_offset(zone, f["taken"])[0] if zone else None
                    off = off if off is not None else offset
                    rows.append((f["name"], f["size"], f["path"], "accepted", lat, lon, off, f["taken"].isoformat(), label, source, now, None, None, zone))
        else:
            raise GeoFixError("unknown action")
        with self._lock:
            self._db.executemany("INSERT OR REPLACE INTO decisions (name,size,path,status,lat,lon,offset_min,taken,label,source,"
                                 "decided_at,applied_at,applied_note,zone) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
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

    @staticmethod
    def before_after(f: dict, offset: int | None, zone: str) -> dict:
        """What Immich shows for this file today and after the fix. Without a zone in the file Immich reads the clock
        as UTC (server metadata.service.ts getDates; exiftool-vendored defaultVideosToUTC for videos), so the file
        sits that many hours off on the timeline next to photos that know their zone."""
        out: dict = {"name": f["name"]}
        raw_local, raw_off = parse_exif_time(f.get("clock_raw"))
        if raw_local is not None:
            out["before"] = {"local": raw_local.strftime("%Y-%m-%d %H:%M"), "zone": fmt_offset(raw_off) if raw_off is not None else "UTC"}
        if f["taken"] is not None and offset is not None:
            abbr = zone_offset(zone, f["taken"])[1] if zone else ""
            out["after"] = {"local": f["taken"].strftime("%Y-%m-%d %H:%M"), "offset": fmt_offset(offset), "abbr": abbr, "zone": zone}
            if raw_local is not None:
                before_utc = raw_local - timedelta(minutes=raw_off or 0)
                out["shift_minutes"] = int((f["taken"] - timedelta(minutes=offset) - before_utc).total_seconds() // 60)
        return out

    def describe(self) -> dict:
        decided = self._decision_rows()
        saved = self.saved_places()
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
                            "offset_min": first["offset_min"], "zone": first.get("zone") or "", "source": first["source"],
                            "applied": applied, "notes": dict(notes)}
            f0 = s["need"][0]
            example = None
            off = decision["offset_min"] if decision and decision["status"] == "accepted" else None
            if off is not None and f0["taken"] is not None:
                example = {"name": f0["name"], "local": f0["taken"].strftime("%Y-%m-%d %H:%M"), "offset": fmt_offset(off),
                           "utc": (f0["taken"] - timedelta(minutes=off)).strftime("%Y-%m-%d %H:%M")}
                example.update(self.before_after(f0, off, decision["zone"]))
            suggestions = []
            for g in s["suggestions"]:
                g = dict(g)
                if g.get("levels"):
                    g["levels"] = [self._level_view(lv, saved) for lv in g["levels"]]
                    for lv in g["levels"]:
                        lv["example"] = self.before_after(f0, lv["offset_min"], lv["zone"])
                suggestions.append(g)
            out.append({
                "id": s["id"], "folder": s["folder"], "start": s["start"].isoformat() if s["start"] else None,
                "end": s["end"].isoformat() if s["end"] else None, "count": len(s["files"]), "need_count": len(s["need"]),
                "needs": dict(Counter(f["need"] for f in s["need"])), "cameras": sorted({f["camera"] for f in s["need"] if f["camera"]}),
                "videos": sum(1 for f in s["need"] if f["video"]),
                "files": [{"path": f["path"], "name": f["name"], "video": f["video"], "taken": f["taken"].isoformat() if f["taken"] else None}
                          for f in s["need"][:FILES_IN_PAYLOAD]],
                "suggestions": suggestions, "searched_hours": s["searched_hours"], "states": dict(states),
                "before": self.before_after(f0, None, "").get("before"),
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

    def thumbnail(self, path: str, big: bool = False) -> bytes:
        """A JPEG frame of a file of the current scan: 320 px wide for the strip, 1280 px (big) for the enlarged view."""
        with self._lock:
            known = any(f["path"] == path for f in self._files)
        if not known:  # only files of the current scan: this is not a general file server
            raise GeoFixError("not a file of the current scan", 404)
        try:
            st = os.stat(path)
        except OSError as ex:
            raise GeoFixError("file is gone", 404) from ex
        os.makedirs(self._thumbs, mode=0o700, exist_ok=True)
        cache = os.path.join(self._thumbs, hashlib.sha1(f"{path}|{st.st_size}|{st.st_mtime}".encode()).hexdigest() + ("-big" if big else "") + ".jpg")
        if os.path.isfile(cache) and os.path.getsize(cache) > 0:
            with open(cache, "rb") as fh:
                return fh.read()
        stem = os.path.splitext(path)[0]
        source, video = path, path.rsplit(".", 1)[-1].lower() in VIDEO_EXT
        for thm in (stem + ".THM", stem + ".thm"):  # older GoPros leave a ready-made thumbnail next to each video
            if os.path.isfile(thm):
                source, video = thm, False
                break
        with self._thumb_gate:
            self._frame(source, video, cache, big)
        with open(cache, "rb") as fh:
            return fh.read()

    def _frame(self, source: str, video: bool, out: str, big: bool) -> None:
        """One JPEG frame of `source` into `out` (written atomically): 320 px wide, or 1280 px when big."""
        if not shutil.which(self._ffmpeg):
            raise GeoFixError("no preview (ffmpeg is not installed in the bridge container)", 404)
        tmp = out + f".{threading.get_ident()}.tmp.jpg"
        cmd = [self._ffmpeg, "-nostdin", "-loglevel", "error", "-y"] + (["-ss", "1"] if video else []) + \
              ["-i", source, "-frames:v", "1", "-vf", f"scale='min({1280 if big else 320},iw)':-2", "-q:v", "4" if big else "6", tmp]
        try:
            proc = subprocess.run(cmd, capture_output=True, timeout=120)
            if video and (proc.returncode != 0 or not os.path.isfile(tmp) or os.path.getsize(tmp) == 0):
                cmd.remove("-ss"), cmd.remove("1")  # shorter than a second
                proc = subprocess.run(cmd, capture_output=True, timeout=120)
        except (OSError, subprocess.SubprocessError) as ex:
            raise GeoFixError("no preview for this file", 404) from ex
        if proc.returncode != 0 or not os.path.isfile(tmp) or os.path.getsize(tmp) == 0:
            if os.path.exists(tmp):
                os.remove(tmp)
            raise GeoFixError("no preview for this file", 404)
        os.replace(tmp, out)

    def immich_preview(self, client, asset_id: str, big: bool) -> tuple[bytes, str]:
        """Immich's own preview of one of the person's photos; when Immich has none (seen on real videos: HTTP 404
        'Asset media not found' although the original is there), the original is downloaded once, both sizes are
        made from it with ffmpeg and cached, and the download is deleted."""
        try:
            return client.thumbnail(asset_id, "preview" if big else "thumbnail")
        except ImmichError as ex:
            if "HTTP 404" not in str(ex):
                raise
        os.makedirs(self._thumbs, mode=0o700, exist_ok=True)
        small, large = (os.path.join(self._thumbs, f"immich-{asset_id}{s}.jpg") for s in ("", "-big"))
        want = large if big else small
        if not os.path.isfile(want):
            with self._thumb_gate:
                if not os.path.isfile(want):
                    original = os.path.join(self._thumbs, f"immich-{asset_id}.{threading.get_ident()}.original")
                    try:
                        mime = client.download_original(asset_id, original, ORIGINAL_MAX_BYTES)
                        for out, b in ((small, False), (large, True)):
                            self._frame(original, mime.startswith("video/"), out, b)
                    except ImmichError as ex:
                        raise GeoFixError(f"no preview: {ex}", 404) from ex
                    finally:
                        if os.path.exists(original):
                            os.remove(original)
        with open(want, "rb") as fh:
            return fh.read(), "image/jpeg"
