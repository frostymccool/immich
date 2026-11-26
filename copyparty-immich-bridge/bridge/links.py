"""Albums shared as a link (Google Photos, Google Drive): read, name, download to the NAS, import, then tidy up.

A person pastes a link on the bridge page (or the phone app sends it). The bridge reads the album, suggests a few
names (the first is used unless they pick or type another), downloads every original into a new folder inside that
person's own upload folder, and queues each file for import as it lands. The folder name becomes the Immich album,
as for any upload. Once a file is safely in Immich (same checksum) and automatic correction has finished with it
(or LINK_KEEP_DAYS have passed), the NAS copy the bridge itself downloaded is deleted: the owner chose "save to the
NAS, then Immich, handle all corrections and the NAS copy can be deleted". Files the bridge did not download are
never touched.

Only https links to the known services are read, and downloads only follow redirects to Google's own hosts, so a
pasted link cannot make the bridge fetch from the LAN.
"""

from __future__ import annotations

import collections
import hashlib
import html
import logging
import os
import re
import sqlite3
import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Callable
from urllib.parse import urlparse

import requests

log = logging.getLogger(__name__)

UA = "Mozilla/5.0 (copyparty-immich-bridge)"
KEEP_DAYS = float(os.environ.get("LINK_KEEP_DAYS", "7"))
MAX_ITEMS = 5000
MAX_FILE = 20 * 1024 ** 3
PAGE_HOSTS = {"photos.app.goo.gl", "photos.google.com", "goo.gl", "drive.google.com"}
FETCH_SUFFIXES = ("googleusercontent.com", "google.com", "goo.gl")
BAD_NAME = re.compile(r'[\\/:*?"<>|\x00-\x1f]+')


class LinkError(Exception):
    def __init__(self, message: str, status: int = 400):
        super().__init__(message)
        self.status = status


@dataclass
class Item:
    key: str
    url: str
    video: bool = False
    name: str = ""
    ts: int | None = None  # ms, as the service stores it
    tz: int = 0  # ms offset the service stores with it
    camera: str = ""


@dataclass
class Album:
    source: str
    title: str
    items: list[Item] = field(default_factory=list)


# ---------------------------------------------------------------------------------------------- reading the link


def _allowed(url: str, hosts) -> bool:
    u = urlparse(url)
    host = (u.hostname or "").lower()
    return u.scheme == "https" and (host in hosts if isinstance(hosts, set) else host.endswith(hosts))


def _get(session: requests.Session, url: str, **kw) -> requests.Response:
    resp = session.get(url, headers={"User-Agent": UA}, timeout=kw.pop("timeout", 60), **kw)
    for hop in [*resp.history, resp]:
        if not _allowed(hop.url, FETCH_SUFFIXES):
            resp.close()
            raise LinkError("that link leads somewhere the bridge does not download from")
    return resp


def read_album(url: str, session: requests.Session | None = None) -> Album:
    url = (url or "").strip()
    if not _allowed(url, PAGE_HOSTS):
        raise LinkError("paste a Google Photos shared album link (photos.app.goo.gl/...) or a Google Drive folder link")
    s = session or requests.Session()
    if urlparse(url).hostname == "drive.google.com":
        m = re.search(r"/folders/([A-Za-z0-9_-]{10,})", url)
        if not m:
            raise LinkError("that Google Drive link is not a folder link (drive.google.com/drive/folders/...)")
        return _read_drive(m.group(1), s)
    resp = _get(s, url)
    if resp.status_code != 200:
        raise LinkError(f"the album could not be opened (HTTP {resp.status_code}); is it still shared?")
    if not _allowed(resp.url, {"photos.google.com"}):
        raise LinkError("that link is not a Google Photos shared album")
    return _parse_google_photos(resp.text)


def _parse_google_photos(page: str) -> Album:
    t = re.search(r'<meta property="og:title" content="([^"]*)"', page) or re.search(r"<title>([^<]*)", page)
    title = html.unescape(t.group(1)) if t else ""
    title = re.sub(r"\s+·\s.*$|\s+[-–]\s+Google Photos$", "", title).strip()  # "Trip · 25 Nov 2026", "... - Google Photos"
    starts = [(m.start(), m.group(1), m.group(2)) for m in
              re.finditer(r'\["(AF1Qip[\w-]+)",\["(https://lh3\.googleusercontent\.com/pw/[\w-]+)",(?=\d)', page)]
    items: dict[str, Item] = {}
    for n, (pos, key, link) in enumerate(starts):
        seg = page[pos:starts[n + 1][0] if n + 1 < len(starts) else pos + 6000]
        it = items.setdefault(key, Item(key=key, url=link))
        m = re.search(r"\],(\d{13}),\"[^\"]*\",(-?\d+),", seg)
        if m and it.ts is None:
            it.ts, it.tz = int(m.group(1)), int(m.group(2))
        it.video = it.video or "76647426" in seg  # the key Google Photos uses for a video's details
        cam = re.search(r'\[\d+,\d+,\d+,null,\["([^"]*)","([^"]+)"', seg)
        if cam and not it.camera:
            it.camera = cam.group(2)
    if not items:
        raise LinkError("no photos or videos were found in that album (is it shared with 'anyone with the link'?)")
    return Album("Google Photos", title, list(items.values())[:MAX_ITEMS])


def _read_drive(folder: str, s: requests.Session) -> Album:
    resp = _get(s, f"https://drive.google.com/embeddedfolderview?id={folder}")
    if resp.status_code != 200:
        raise LinkError(f"the Drive folder could not be opened (HTTP {resp.status_code}); is it shared with anyone with the link?")
    page = resp.text
    t = re.search(r"<title>([^<]*)", page)
    entries = re.findall(r'id="entry-([^"]+)".*?flip-entry-title">([^<]+)<', page, re.S)
    items = [Item(key=i, url=f"https://drive.usercontent.google.com/download?id={i}&export=download&confirm=t",
                  name=html.unescape(n).strip(), video=n.lower().rsplit(".", 1)[-1] in {"mp4", "mov", "m4v", "avi", "mts", "insv"})
             for i, n in entries if "." in n]
    if not items:
        raise LinkError("no files were found in that Drive folder (subfolders are not read)")
    return Album("Google Drive", html.unescape(t.group(1)).strip() if t else "", items[:MAX_ITEMS])


# ---------------------------------------------------------------------------------------------- naming


def clean_name(name: str) -> str:
    name = re.sub(r"\.{2,}", " ", BAD_NAME.sub(" ", name or "")).strip(" .")
    return re.sub(r"\s{2,}", " ", name)[:80]


def album_days(album: Album) -> list[str]:
    days = collections.Counter(datetime.fromtimestamp((i.ts + i.tz) / 1000, timezone.utc).strftime("%Y-%m-%d")
                               for i in album.items if i.ts)
    return [d for d, _ in days.most_common()]


def short_camera(model: str) -> str:
    for brand in ("GoPro ", "Insta360 "):
        if model.startswith(brand):
            return model[len(brand):]
    return model


def suggest_names(album: Album, place: str = "", today: str | None = None) -> list[str]:
    """Up to 4 names, best first. The first is what happens when the person just presses Import."""
    days = album_days(album)
    day = days[0] if days else (today or datetime.now().strftime("%Y-%m-%d"))
    cams = collections.Counter(short_camera(i.camera) for i in album.items if i.camera)
    camera = cams.most_common(1)[0][0] if cams else ""
    title = clean_name(album.title)
    tday = "" if not title else title if day in title else f"{title} {day}"
    picks = [f"{place} {day}" if place else "", f"{place} {day} {camera}" if place and camera else "", tday, title,
             f"{camera} {day}" if camera else "", f"Shared album {day}"]
    out: list[str] = []
    for p in picks:
        p = clean_name(p)
        if p and p.lower() not in {o.lower() for o in out}:
            out.append(p)
    return out[:4]


def place_from_library(client, album: Album) -> str:
    """The town of the person's own geotagged Immich photos taken during the album's time, or ''."""
    stamps = [i.ts - i.tz for i in album.items if i.ts]  # roughly UTC; a zone-less camera can be hours off
    if not stamps or client is None:
        return ""
    start = datetime.fromtimestamp(min(stamps) / 1000, timezone.utc) - timedelta(hours=12)
    end = datetime.fromtimestamp(max(stamps) / 1000, timezone.utc) + timedelta(hours=12)
    try:
        body = client.search_metadata({"takenAfter": start.isoformat(), "takenBefore": end.isoformat(),
                                       "withExif": True, "size": 1000})
    except Exception as ex:  # noqa: BLE001 - a name suggestion is never worth failing for
        log.info("no place suggestion (Immich search failed: %s)", ex)
        return ""
    towns = collections.Counter()
    for a in (body.get("assets") or {}).get("items") or []:
        ex = a.get("exifInfo") or {}
        if ex.get("city"):
            towns[ex["city"]] += 1
    return towns.most_common(1)[0][0] if towns else ""


# ---------------------------------------------------------------------------------------------- jobs


@dataclass
class Person:
    """What the link importer needs of one person: where their folder is, their worker, their Immich."""
    uid: str
    folder: str
    enqueue: Callable[[str, str], bool]
    client: object
    state: object


class LinkImports:
    def __init__(self, db_path: str, person: Callable[[str], Person | None], corrections_done: Callable[[str, str], bool] = lambda uid, asset: True,
                 session_factory: Callable[[], requests.Session] = requests.Session, clock: Callable[[], float] = time.time):
        self._person = person
        self._corrections_done = corrections_done
        self._session = session_factory
        self._clock = clock
        self._lock = threading.Lock()
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.execute("""CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, uid TEXT, url TEXT, source TEXT, name TEXT,
            folder TEXT, created REAL, state TEXT, total INTEGER, done INTEGER, skipped INTEGER, failed INTEGER, bytes INTEGER,
            error TEXT)""")
        self._db.execute("""CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, job TEXT, uid TEXT, size INTEGER,
            sha1 TEXT, added REAL, deleted_at REAL)""")
        self._db.execute("UPDATE jobs SET state='stopped', error='the bridge restarted during the download; paste the link again to finish' WHERE state='running'")
        self._db.commit()
        self._looked: dict[tuple[str, str], tuple[float, Album]] = {}

    # -- looking ---------------------------------------------------------------------------------------

    def _album(self, url: str, uid: str) -> Album:
        key = (uid, url.strip())
        hit = self._looked.get(key)
        if hit and self._clock() - hit[0] < 600:
            return hit[1]
        album = read_album(url, self._session())
        self._looked[key] = (self._clock(), album)
        return album

    def inspect(self, url: str, uid: str) -> dict:
        p = self._person(uid)
        if p is None:
            raise LinkError("unknown person", 404)
        album = self._album(url, uid)
        names = suggest_names(album, place_from_library(p.client, album))
        days = album_days(album)
        return {"source": album.source, "title": album.title, "photos": sum(not i.video for i in album.items),
                "videos": sum(i.video for i in album.items), "days": sorted(days), "suggestions": names,
                "folder": os.path.basename(p.folder.rstrip("/")) if p.folder else ""}

    # -- importing -------------------------------------------------------------------------------------

    def start(self, url: str, name: str, uid: str) -> dict:
        p = self._person(uid)
        if p is None:
            raise LinkError("unknown person", 404)
        if not p.folder or not os.path.isdir(p.folder):
            raise LinkError("this person has no upload folder the bridge can see", 409)
        if not os.access(p.folder, os.W_OK):
            raise LinkError("the bridge can only read the upload folders; re-run the installer with WRITABLE=1 "
                            "(see INSTALL.md) so it can save shared albums", 409)
        name = clean_name(name)
        if not name:
            raise LinkError("give the album a name")
        album = self._album(url, uid)
        dest = os.path.join(p.folder, name)
        if os.path.relpath(os.path.realpath(dest), os.path.realpath(p.folder)).startswith(".."):
            raise LinkError("that name is not allowed")
        jid = uuid.uuid4().hex[:12]
        with self._lock:
            self._db.execute("INSERT INTO jobs VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                             (jid, uid, url.strip(), album.source, name, dest, self._clock(), "running", len(album.items), 0, 0, 0, 0, None))
            self._db.commit()
        threading.Thread(target=self._run, args=(jid, album, dest, p), name=f"link-{jid}", daemon=True).start()
        log.info("link import %s for %s: %d files from %s into %s", jid, uid, len(album.items), album.source, name)
        return self.job(jid)

    def _bump(self, jid: str, **delta) -> None:
        sets = ", ".join(f"{k}={k}+?" for k in delta)
        with self._lock:
            self._db.execute(f"UPDATE jobs SET {sets} WHERE id=?", (*delta.values(), jid))
            self._db.commit()

    def _run(self, jid: str, album: Album, dest: str, p: Person) -> None:
        s = self._session()
        try:
            os.makedirs(dest, exist_ok=True)
            for it in album.items:
                try:
                    got = self._download(s, it, dest)
                except Exception as ex:  # noqa: BLE001 - one bad file never stops the album
                    log.warning("link import %s: %s failed: %s", jid, it.name or it.key, ex)
                    self._bump(jid, failed=1)
                    continue
                if got is None:
                    self._bump(jid, skipped=1)
                    continue
                path, size, sha1 = got
                with self._lock:
                    self._db.execute("INSERT OR REPLACE INTO files VALUES (?,?,?,?,?,?,NULL)", (path, jid, p.uid, size, sha1, self._clock()))
                    self._db.commit()
                self._bump(jid, done=1, bytes=size)
                p.enqueue(path, "shared link")
            state, err = "finished", None
        except Exception as ex:  # noqa: BLE001
            log.exception("link import %s stopped", jid)
            state, err = "failed", str(ex)[:300]
        with self._lock:
            self._db.execute("UPDATE jobs SET state=?, error=? WHERE id=?", (state, err, jid))
            self._db.commit()

    def _download(self, s: requests.Session, it: Item, dest: str) -> tuple[str, int, str] | None:
        url = it.url + ("=dv" if it.video else "=d") if "googleusercontent.com/pw/" in it.url else it.url
        with _get(s, url, stream=True, timeout=(15, 300)) as resp:
            if resp.status_code != 200:
                raise LinkError(f"HTTP {resp.status_code}")
            kind = resp.headers.get("Content-Type", "")
            if not (kind.startswith("image/") or kind.startswith("video/") or kind == "application/octet-stream"):
                raise LinkError(f"not a photo or video ({kind or 'unknown type'})")
            cd = resp.headers.get("Content-Disposition", "")
            m = re.search(r"filename\*=UTF-8''([^;]+)|filename=\"?([^\";]+)", cd)
            name = clean_name(requests.utils.unquote(m.group(1) or m.group(2)) if m else it.name) or f"{it.key[-10:]}.{'mp4' if it.video else 'jpg'}"
            part = os.path.join(dest, f".{name}.part")
            h, size = hashlib.sha1(), 0
            with open(part, "wb") as fh:
                for chunk in resp.iter_content(1 << 20):
                    size += len(chunk)
                    if size > MAX_FILE:
                        raise LinkError("file too big")
                    h.update(chunk)
                    fh.write(chunk)
        sha1 = h.hexdigest()
        final = os.path.join(dest, name)
        if os.path.exists(final):
            if os.path.getsize(final) == size and _sha1(final) == sha1:
                os.remove(part)
                return None  # already here (a second paste of the same link)
            stem, dot, ext = name.rpartition(".")
            final = os.path.join(dest, f"{stem or name}_{it.key[-6:]}{dot}{ext if stem else ''}")
            if os.path.exists(final):
                os.remove(part)
                return None
        os.rename(part, final)
        return final, size, sha1

    # -- reporting -------------------------------------------------------------------------------------

    _COLS = ("id", "uid", "url", "source", "name", "folder", "created", "state", "total", "done", "skipped", "failed", "bytes", "error")

    def job(self, jid: str) -> dict:
        with self._lock:
            row = self._db.execute("SELECT * FROM jobs WHERE id=?", (jid,)).fetchone()
        return self._view(row) if row else {}

    def jobs(self, uid: str | None = None, limit: int = 10) -> list[dict]:
        with self._lock:
            q = "SELECT * FROM jobs" + (" WHERE uid=?" if uid else "") + " ORDER BY created DESC LIMIT ?"
            rows = self._db.execute(q, ((uid, limit) if uid else (limit,))).fetchall()
            left = dict(self._db.execute("SELECT job, COUNT(*) FROM files WHERE deleted_at IS NULL GROUP BY job").fetchall())
        out = []
        for r in rows:
            v = self._view(r)
            v["kept_on_nas"] = left.get(v["id"], 0)
            out.append(v)
        return out

    def _view(self, row) -> dict:
        v = dict(zip(self._COLS, row))
        v.pop("folder", None)
        v.pop("url", None)  # the link itself is not shown back (it is the album's key)
        return v

    # -- tidying the NAS copies ------------------------------------------------------------------------

    def cleanup(self) -> int:
        """Deletes NAS copies this bridge downloaded once Immich has the same bytes and correction is done."""
        with self._lock:
            rows = self._db.execute("SELECT path, uid, size, sha1, added FROM files WHERE deleted_at IS NULL").fetchall()
        removed, folders = 0, set()
        for path, uid, size, sha1, added in rows:
            p = self._person(uid)
            if p is None:
                continue
            if not os.path.exists(path):
                self._mark_deleted(path)
                continue
            rec = p.state.get(path)
            if rec is None or rec.status not in ("imported", "duplicate") or rec.sha1 != sha1:
                continue
            try:
                if os.path.getsize(path) != size or not self._in_immich(p.client, rec.asset_id, sha1, path):
                    continue
            except Exception as ex:  # noqa: BLE001 - when in doubt, keep the file
                log.info("keeping %s for now (%s)", path, ex)
                continue
            done = self._corrections_done(uid, rec.asset_id or "")
            if not done and self._clock() - (added or 0) < KEEP_DAYS * 86400:
                continue
            try:
                os.remove(path)
            except OSError as ex:
                log.warning("could not delete the NAS copy %s: %s", path, ex)
                continue
            self._mark_deleted(path)
            folders.add(os.path.dirname(path))
            removed += 1
        for d in folders:
            try:
                os.rmdir(d)  # only when nothing else is in it
            except OSError:
                pass
        if removed:
            log.info("deleted %d NAS copies of shared-album files that are safely in Immich", removed)
        return removed

    @staticmethod
    def _in_immich(client, asset_id: str | None, sha1: str, path: str) -> bool:
        if asset_id and asset_id != "present":
            try:
                a = client.get_asset(asset_id)
                return bool(a) and not a.get("isTrashed")
            except Exception:  # noqa: BLE001
                return False
        return client.find_by_checksum(sha1, ref_id=path) is not None

    def _mark_deleted(self, path: str) -> None:
        with self._lock:
            self._db.execute("UPDATE files SET deleted_at=? WHERE path=?", (self._clock(), path))
            self._db.commit()


def _sha1(path: str) -> str:
    h = hashlib.sha1()
    with open(path, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()

