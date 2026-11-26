"""HTTP endpoints: the copyparty hook receiver plus status/health.

POST /hook    body = the JSON copyparty's xau hook produced (single object),
              or a JSON list (xiu batch mode). Returns {"queued": n}.
GET  /status  state-DB counters, queue size, recent items.
GET  /healthz liveness probe.
GET  /        the web page (settings, folder picker, status, logs).
/api/*        the web page's backend: config, folder browser, logs, scan.

With BRIDGE_TOKEN set, /hook and every /api/* call must present it
(`X-Bridge-Token: <token>` or `Authorization: Bearer <token>`). With no token the
/api/* endpoints refuse to answer at all, so settings can never be changed
anonymously. /healthz and /status stay open (the phone app reads them).
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import re
import threading
import time
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import requests

from bridge import __version__
from bridge.browse import BrowseError, list_dir
from bridge.config import Config
from bridge.geofix import GeoFix, GeoFixError
from bridge.immich import ImmichError
from bridge.logbuffer import RingLogHandler
from bridge.links import LinkError, LinkImports
from bridge.manager import UserManager
from bridge.pressure import PRESSURE
from bridge.scanner import is_within_dirs
from bridge.settings import SettingsError, SettingsStore
from bridge.state import StateStore
from bridge.users import MAIN_ID, UsersError
from bridge.worker import ImportWorker

log = logging.getLogger("bridge.server")

MAX_HOOK_BODY = 4 * 1024 * 1024
MAX_API_BODY = 256 * 1024
STARTED_AT = time.time()
_UI_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web", "index.html")


def _load_ui() -> bytes:
    try:
        with open(_UI_PATH, "rb") as fh:
            return fh.read()
    except OSError:
        return b"<h1>web page missing from this build</h1>"


def status_extras(geofix) -> dict:
    """Counts only (no names or paths): safe for the open /status."""
    out: dict = {}
    auto = getattr(geofix, "autofix", None)
    if auto is not None:
        try:
            out["autofix"] = {"on": bool(getattr(auto, "enabled", lambda: False)()), "counts": auto.describe(0)["counts"],
                              "clocks_set": auto.describe(0).get("clock_counts", {}).get("decided", 0)}
        except Exception:
            pass
    stacker = getattr(geofix, "stacker", None)
    if stacker is not None:
        try:
            out["raw_stacks"] = stacker.describe()
        except Exception:
            pass
    mq = getattr(geofix, "mqtt", None)
    if mq is not None:
        out["mqtt"] = {"on": bool(mq.url()), "connected": mq.connected, "error": mq.last_error[:120] if mq.last_error else ""}
    return out


class TokenCheck:
    """Who an Immich access token (the phone app's sign-in) belongs to, asked of Immich itself.

    Accepted tokens are remembered for 5 minutes and refused ones for 60 s, keyed by a sha256 of the token, so a
    phone polling /status/me (or a wrong token tried in a loop) does not cost an Immich call each time. The token
    itself is never stored, logged or put in a URL."""

    OK_S, BAD_S = 300, 60

    def __init__(self, immich_url: Callable[[], str], verify_tls: Callable[[], bool] = lambda: True,
                 clock: Callable[[], float] = time.monotonic):
        self._url = immich_url  # read at each check: the Immich address can be changed on the page
        self._verify = verify_tls
        self._clock = clock
        self._cache: dict[str, tuple[float, str, dict | None]] = {}
        self._lock = threading.Lock()

    def check(self, token: str) -> tuple[str, dict | None]:
        """("ok", {"id", "name", "email"}) | ("bad", None) | ("down", None): Immich could not be asked."""
        key = hashlib.sha256(token.encode()).hexdigest()
        now = self._clock()
        with self._lock:
            hit = self._cache.get(key)
            if hit and hit[0] > now:
                return hit[1], hit[2]
        try:
            resp = requests.get(self._url().rstrip("/") + "/api/users/me", timeout=10, verify=self._verify(),
                                headers={"x-immich-user-token": token, "Accept": "application/json"})
        except requests.RequestException:
            return "down", None
        if resp.status_code in (401, 403):
            verdict, who, ttl = "bad", None, self.BAD_S
        elif resp.status_code != 200:
            return "down", None
        else:
            try:
                body = resp.json()
                who = {"id": str(body.get("id") or "").lower(), "name": str(body.get("name") or ""),
                       "email": str(body.get("email") or "")}
            except (ValueError, AttributeError):
                return "down", None
            verdict, ttl = ("ok", self.OK_S) if who["id"] else ("bad", self.BAD_S)
        with self._lock:
            if len(self._cache) > 1000:
                self._cache = {k: v for k, v in self._cache.items() if v[0] > now}
            self._cache[key] = (now + ttl, verdict, who)
        return verdict, who


def llms_txt(cfg: Config) -> str:
    """What another agent or person needs to read this bridge's state. Open: holds no secrets and no paths."""
    page = cfg.public_url or "http://<this host>:%d" % cfg.bind_port
    return f"""# copyparty-immich-bridge {__version__}

Imports files uploaded to copyparty into Immich, then (optionally) corrects place and time zone from the account's own
geotagged photos. Human page: {page}/ (token required).

## Scope for other agents
Read-only. Nothing here is meant to be changed by other agents; settings need the bridge token, which only the user has.

## MQTT (prefix "ImmichBridge/"{', broker ' + cfg.mqtt_url.split('@')[-1] if cfg.mqtt_url else ', currently switched off'})
State (retained, refreshed at least every 60 s):
  ImmichBridge/node                    ON | OFF (last will: OFF when the bridge stops or loses the connection)
  ImmichBridge/state/updated           ISO-8601 UTC time of the last refresh; older than 5 min = the bridge is down
  ImmichBridge/device/version          software version
  ImmichBridge/state/queue             files waiting to be imported (all people)
  ImmichBridge/state/paused            ON | OFF (paused by the user)
  ImmichBridge/state/backoff           ON | OFF (holding off by itself because Immich or its server is overloaded)
  ImmichBridge/state/backoff_reason    why, in words ("none" when not backing off)
  ImmichBridge/state/backoff_until     ISO-8601 UTC time of the next check ("none" when not backing off)
  ImmichBridge/state/imported_total    files imported by the bridge (all people)
  ImmichBridge/state/autofix           JSON counts of automatic place/time corrections: applied, review, ...
  ImmichBridge/state/summary           JSON with all of the above
Events (not retained):
  ImmichBridge/event                   JSON {{t, level, src, msg}}: backing off, resuming
Commands: none.

## HTTP (open)
GET {page}/healthz      liveness and version
GET {page}/status       totals, queue, backoff (per-person detail needs the token)
GET {page}/status/me    one person's own status; header X-Immich-Token = their Immich access token (https only)
GET {page}/llms.txt     this text

## Shared albums (token, or X-Immich-Token for the signed-in person only)
POST {page}/api/links/inspect  {{"url"}} -> title, counts, days, name suggestions (first = default),
                               imported_before (skipped on import), look_alikes (same time or name already in Immich)
POST {page}/api/links/import   {{"url", "name"?}} -> job; downloads into the person's folder, imports, then deletes
                               the NAS copy once Immich has the same bytes and correction is done
GET  {page}/api/links          recent jobs, each with stages: downloaded, on_nas, uploading, in_immich, not_taken
                               (+ not_taken_reason), corrected, checked, waiting (corrects = false: no correction runs)
"""


def make_handler(
    cfg: Config,
    state: StateStore,
    worker: ImportWorker,
    settings: SettingsStore | None = None,
    logs: RingLogHandler | None = None,
    scan_now: Callable[[], None] | None = None,
    manager: UserManager | None = None,
    geofix: GeoFix | None = None,
    links: LinkImports | None = None,
) -> type[BaseHTTPRequestHandler]:
    tokens = TokenCheck(lambda: cfg.immich_url, lambda: cfg.verify_tls)

    class Handler(BaseHTTPRequestHandler):
        server_version = f"copyparty-immich-bridge/{__version__}"

        def log_message(self, fmt: str, *args) -> None:  # route to logging, not stderr
            log.debug("%s " + fmt, self.address_string(), *args)

        def _send_json(self, code: int, payload: dict) -> None:
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        # -- helpers ---------------------------------------------------------------

        def _send_bytes(self, code: int, body: bytes, ctype: str, extra: dict[str, str] | None = None) -> None:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def _authorized(self) -> bool:
            """True when no token is configured, or the request carries the right one."""
            if not cfg.token:
                return True
            supplied = self.headers.get("X-Bridge-Token", "")
            if not supplied:
                auth = self.headers.get("Authorization", "")
                if auth.lower().startswith("bearer "):
                    supplied = auth[7:].strip()
            return hmac.compare_digest(supplied.encode(), cfg.token.encode())

        def _require_api(self) -> bool:
            """Gate for /api/*: a token must exist AND be presented."""
            if not cfg.token:
                self._send_json(403, {"error": "BRIDGE_TOKEN is not set, so the settings API is switched off"})
                return False
            if not self._authorized():
                time.sleep(0.4)  # slows down guessing
                self._send_json(401, {"error": "missing or wrong token"})
                return False
            return True

        def _clen(self) -> int:
            try:
                return int(self.headers.get("Content-Length") or 0)
            except ValueError:
                return -1

        def _read_json_body(self) -> dict | None:
            length = self._clen()
            if length <= 0 or length > MAX_API_BODY:
                self._send_json(400, {"error": "bad content length"})
                return None
            try:
                body = json.loads(self.rfile.read(length))
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "invalid json"})
                return None
            if not isinstance(body, dict):
                self._send_json(400, {"error": "expected a json object"})
                return None
            return body

        def _ctx(self, query: dict | None = None, body: dict | None = None):
            """(worker, state) of the person the request is about (?user= or {"user":..}, default main).
            Sends the 404 itself and returns None for an unknown person."""
            uid = ((query or {}).get("user") or [None])[0] or (body or {}).get("user") or MAIN_ID
            if manager is None:
                return (worker, state) if uid == MAIN_ID else self._no_user()
            rt = manager.runtime(uid) if isinstance(uid, str) else None
            if rt is None:
                return self._no_user()
            return rt.worker, rt.state

        def _no_user(self):
            self._send_json(404, {"error": "no such user"})
            return None

        def _multi(self) -> bool:
            return manager is not None and bool(manager.users.users())

        def _config_payload(self, w: ImportWorker | None = None) -> dict:
            assert settings is not None
            w = w or worker
            return {
                "values": settings.values(),
                "defaults": settings.defaults(),
                "overridden": settings.overridden(),
                "readonly": {
                    "version": __version__,
                    "build": cfg.build,
                    "immich_url": cfg.immich_url,
                    "api_key_set": bool(cfg.api_key),
                    "user": w.user_id,
                    "multi": self._multi(),
                    "bind_port": cfg.bind_port,
                    "workers": cfg.workers,
                    "device_id": cfg.device_id,
                    "immich_user": w.immich_user,
                    "account_change": w.account_change,
                    "albums": w.album_links(cfg.immich_url),
                    "state_db": cfg.state_db,
                    "settings_file": cfg.settings_file,
                    "uptime_seconds": int(time.time() - STARTED_AT),
                },
                "browse_roots": settings.browse_roots,
            }

        def _send_status(self, query: dict, me: str | None = None, extra: dict | None = None) -> None:
            """/status is open (the phone app reads it): without the bridge token it carries totals only, no
            folders, albums, file names or paths (the keys stay, empty, so older app builds still read it). With
            the token, or for /status/me (`me` = the bridge user an Immich sign-in was matched to), the detail."""
            full = bool(cfg.token) and self._authorized()
            sent: dict = {}
            real = self._send_json

            def capture(code: int, payload: dict) -> None:
                if code == 200 and me is None and not full:
                    payload = {**payload, "watch_dirs": [], "priority_dirs": [], "albums": {}, "recent": [], "active": []}
                    payload.pop("extras", None)
                if code == 200 and me is not None:
                    payload = {**payload, **(extra or {})}
                    if me != MAIN_ID:
                        payload.pop("extras", None)
                sent["done"] = True
                real(code, payload)

            self._send_json = capture  # type: ignore[method-assign]
            try:
                self._status_body(query if me is None else {"user": [me]}, me is not None)
            finally:
                self._send_json = real  # type: ignore[method-assign]

        def _immich_caller(self):
            """(bridge uid, Immich user) of the X-Immich-Token sender; sends the error itself and returns None."""
            token = self.headers.get("X-Immich-Token", "").strip()
            if not token:
                self._send_json(401, {"error": "no token"})
                return None
            verdict, who = tokens.check(token)
            if verdict == "down":
                self._send_json(503, {"error": "immich unreachable"})
                return None
            if verdict != "ok" or who is None:
                self._send_json(401, {"error": "token not accepted"})
                return None
            uid = None
            if manager is None:
                if (worker.immich_user or {}).get("id", "").lower() == who["id"]:
                    uid = MAIN_ID
            else:
                for rt in manager.runtimes():
                    known = (rt.worker.immich_user or {}).get("id") or ""
                    if not known and rt.uid != MAIN_ID:
                        u = manager.users.get(rt.uid)
                        known = u.immich_id if u else ""
                    if known and known.lower() == who["id"]:
                        uid = rt.uid
                        break
            if uid is None:
                self._send_json(404, {"error": "not a bridge user"})
                return None
            return uid, who

        def _link_caller(self, query: dict | None = None, body: dict | None = None) -> str | None:
            """Who a shared-link request is for: the page (bridge token, ?user= / {"user"}, default main) or the
            phone app (X-Immich-Token: only ever the signed-in person themselves)."""
            if self.headers.get("X-Immich-Token") and not self.headers.get("X-Bridge-Token"):
                caller = self._immich_caller()
                return caller[0] if caller else None
            if not self._require_api():
                return None
            uid = ((query or {}).get("user") or [None])[0] or (body or {}).get("user") or MAIN_ID
            if not isinstance(uid, str) or (manager is not None and manager.runtime(uid) is None) or (manager is None and uid != MAIN_ID):
                self._no_user()
                return None
            return uid

        def _links_post(self) -> None:
            assert links is not None
            body = self._read_json_body()
            if body is None:
                return
            uid = self._link_caller(body=body)
            if uid is None:
                return
            url = body.get("url")
            if not isinstance(url, str) or not url.strip():
                self._send_json(400, {"error": "paste the album link"})
                return
            try:
                if self.path == "/api/links/inspect":
                    self._send_json(200, links.inspect(url, uid))
                else:
                    name = body.get("name")
                    if name is None or (isinstance(name, str) and not name.strip()):
                        name = links.inspect(url, uid)["suggestions"][0]  # nothing chosen = the first suggestion
                    if not isinstance(name, str):
                        self._send_json(400, {"error": "name must be text"})
                        return
                    self._send_json(202, links.start(url, name, uid))
            except LinkError as ex:
                self._send_json(ex.status, {"error": str(ex)})
            except requests.RequestException as ex:
                self._send_json(502, {"error": f"the album could not be read: {type(ex).__name__}"})

        def _send_status_me(self) -> None:
            """The phone app's own view: the signed-in Immich user's bridge status, nobody else's."""
            caller = self._immich_caller()
            if caller is None:
                return
            uid, who = caller
            name = (manager.describe(uid) or {}).get("name", "") if manager else who["name"]
            self._send_status({}, me=uid, extra={"me": {"bridge_user": uid, "name": name}, "immich_user": who})

        def _status_body(self, query: dict, trusted: bool) -> None:
            if (query.get("user") or [None])[0] is not None or self._multi():
                one = (query.get("user") or [None])[0]
                if one is not None:
                    if not trusted and not self._require_api():  # per-person detail is not for the open endpoint
                        return
                    ctx = self._ctx(query)
                    if ctx is None:
                        return
                    parts = [ctx]
                else:
                    parts = [(rt.worker, rt.state) for rt in manager.runtimes()] if manager else [(worker, state)]
                counts: dict[str, int] = {}
                for _, st in parts:
                    for k, v in st.counts().items():
                        counts[k] = counts.get(k, 0) + v
                backlog = {"files": 0, "bytes_left": 0, "rate": None, "eta_seconds": None}
                rates, active = [], []
                for w, _ in parts:
                    b = w.backlog()
                    backlog["files"] += b["files"]
                    backlog["bytes_left"] += b["bytes_left"]
                    if b["rate"]:
                        rates.append(b["rate"])
                    active += w.active()
                if rates:
                    backlog["rate"] = sum(rates)
                    backlog["eta_seconds"] = int(backlog["bytes_left"] / backlog["rate"]) if backlog["bytes_left"] else None
                recent = []
                if one is not None:  # paths and error text of one person only for that person's view
                    recent = [
                        {"path": r.path, "status": r.status, "asset_id": r.asset_id, "error": r.error,
                         "attempts": r.attempts, "updated_at": r.updated_at}
                        for r in parts[0][1].recent(20)
                    ]
                dirs = manager.router.union() if manager and one is None else (
                    manager.router.folders_of(one) if manager else cfg.watch_dirs)
                self._send_json(
                    200,
                    {
                        "counts": counts,
                        "queue": sum(w.queue_size for w, _ in parts),
                        "paused": cfg.paused or bool(one and (manager.describe(one) or {}).get("paused")),
                        "active": active,
                        "backlog": backlog,
                        "watch_dirs": dirs,
                        "priority_dirs": (manager.runtime(MAIN_ID).view.priority_dirs if manager and manager.runtime(MAIN_ID) else cfg.priority_dirs) if one in (None, MAIN_ID) else [],
                        "albums": parts[0][0].album_info() if one is not None else worker.album_info(),
                        "recent": recent,
                        "users": len(parts) if one is None else 1,
                        "backoff": PRESSURE.describe(), "extras": status_extras(geofix),
                    },
                )
                return
            recent = [
                {
                    "path": r.path,
                    "status": r.status,
                    "asset_id": r.asset_id,
                    "error": r.error,
                    "attempts": r.attempts,
                    "updated_at": r.updated_at,
                }
                for r in state.recent(20)
            ]
            self._send_json(
                200,
                {
                    "counts": state.counts(),
                    "queue": worker.queue_size,
                    "paused": cfg.paused,
                    "active": worker.active(),
                    "backlog": worker.backlog(),
                    "watch_dirs": manager.router.folders_of(MAIN_ID) if manager else cfg.watch_dirs,
                    "priority_dirs": (manager.runtime(MAIN_ID).view.priority_dirs if manager and manager.runtime(MAIN_ID) else cfg.priority_dirs),
                    "albums": worker.album_info(),
                    "recent": recent,
                    "backoff": PRESSURE.describe(), "extras": status_extras(geofix),
                },
            )

        # -- GET -------------------------------------------------------------------

        # -- Fix locations tab -----------------------------------------------------

        def _client_for(self, uid):
            """The Immich client of the chosen person (their own photos are the evidence)."""
            uid = uid or MAIN_ID
            if manager is None:
                return worker._client if uid == MAIN_ID else None
            rt = manager.runtime(uid) if isinstance(uid, str) else None
            return rt.client if rt is not None else None

        def _geofix_get(self, route: str, query: dict) -> None:
            assert geofix is not None
            one = lambda k: (query.get(k) or [""])[0]  # noqa: E731
            try:
                if route == "/api/geofix":
                    out = geofix.describe()
                    folder = out["status"].get("folder") or ""
                    owner = manager.router.owner(os.path.join(folder, ".x")) if (manager is not None and folder) else None
                    out["watched_by"] = owner
                    self._send_json(200, out)
                elif route == "/api/geofix/thumb":
                    self._send_bytes(200, geofix.thumbnail(one("path"), big=one("big") == "1"), "image/jpeg", {"Cache-Control": "private, max-age=3600"})
                elif route == "/api/geofix/saved-places":
                    self._send_json(200, {"places": geofix.saved_places()})
                elif route == "/api/geofix/auto":
                    auto = getattr(geofix, "autofix", None)
                    self._send_json(200, auto.describe() if auto else {"error": "not running"})
                elif route == "/api/geofix/sidecar":
                    self._send_bytes(200, geofix.preview_sidecar(one("path")), "text/plain; charset=utf-8")
                elif route in ("/api/geofix/immich-thumb", "/api/geofix/places"):
                    client = self._client_for(one("user") or geofix.status.get("user"))
                    if client is None:
                        self._send_json(404, {"error": "no such user"})
                    elif route.endswith("places"):
                        name = " ".join(one("q").split())[:80]
                        places = client.search_places(name) if len(name) >= 2 else []
                        self._send_json(200, {"places": [
                            {"name": str(p.get("name") or ""), "region": ", ".join(str(x) for x in (p.get("admin2name"), p.get("admin1name")) if x),
                             "lat": p.get("latitude"), "lon": p.get("longitude")} for p in places[:20] if isinstance(p, dict)]})
                    else:
                        asset = one("id")
                        if not re.fullmatch(r"[0-9a-fA-F-]{36}", asset):
                            self._send_json(400, {"error": "bad id"})
                            return
                        data, ctype = geofix.immich_preview(client, asset, one("big") == "1")
                        self._send_bytes(200, data, ctype if ctype.startswith("image/") else "image/webp", {"Cache-Control": "private, max-age=3600"})
                else:
                    self._send_json(404, {"error": "not found"})
            except GeoFixError as ex:
                self._send_json(ex.code, {"error": str(ex)})
            except (ImmichError, requests.RequestException) as ex:
                self._send_json(502, {"error": str(ex)})

        def _geofix_post(self) -> None:
            assert geofix is not None
            body = self._read_json_body_optional()
            if body is None:
                return
            try:
                if self.path == "/api/geofix/scan":
                    uid = body.get("user") or MAIN_ID
                    client = self._client_for(uid)
                    if client is None:
                        self._send_json(404, {"error": "no such user"})
                        return
                    geofix.start_scan(body.get("folder"), uid, client.search_metadata, client.search_places)
                elif self.path == "/api/geofix/decide":
                    geofix.decide(str(body.get("session") or ""), str(body.get("action") or ""), body.get("suggestion"),
                                  body.get("custom") if isinstance(body.get("custom"), dict) else None, body.get("level"),
                                  body.get("also") if isinstance(body.get("also"), list) else None)
                elif self.path == "/api/geofix/split":
                    geofix.split(str(body.get("session") or ""))
                elif self.path == "/api/geofix/join":
                    geofix.join(str(body.get("session") or ""), str(body.get("with") or ""))
                elif self.path == "/api/geofix/saved-places":
                    if body.get("delete") is not None:
                        geofix.delete_place(body.get("delete"))
                    else:
                        self._send_json(200, geofix.save_place(body.get("name"), body.get("lat"), body.get("lon"), body.get("radius_m")))
                        return
                elif self.path == "/api/geofix/auto/run":
                    auto = getattr(geofix, "autofix", None)
                    if auto is None:
                        raise GeoFixError("automatic correction is not running", 503)
                    threading.Thread(target=auto.run_once, name="auto-fix-now", daemon=True).start()
                    self._send_json(200, {"started": True})
                    return
                elif self.path == "/api/geofix/accept-confident":
                    self._send_json(200, {"accepted": geofix.accept_confident()})
                    return
                else:
                    self._send_json(404, {"error": "not found"})
                    return
                self._send_json(200, {"ok": True})
            except GeoFixError as ex:
                self._send_json(ex.code, {"error": str(ex)})

        def do_GET(self) -> None:
            url = urlparse(self.path)
            route = url.path
            query = parse_qs(url.query)

            if route in ("/", "/ui", "/index.html"):
                self._send_bytes(200, _load_ui(), "text/html; charset=utf-8")
            elif route == "/healthz":
                self._send_json(200, {"ok": True, "version": __version__, "build": cfg.build})
            elif route == "/status":
                self._send_status(query)
            elif route == "/status/me":
                self._send_status_me()
            elif route == "/llms.txt":
                body = llms_txt(cfg).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif route == "/api/links" and links is not None:
                uid = self._link_caller(query)
                if uid is not None:
                    self._send_json(200, {"jobs": links.jobs(uid), "backoff": PRESSURE.describe()})
            elif route == "/api/users" and manager is not None:
                if self._require_api():
                    self._send_json(200, manager.describe_all())
            elif route == "/api/people-folders" and manager is not None:
                if self._require_api():
                    self._send_json(200, manager.people_folders())
            elif route.startswith("/api/users/") and route.endswith("/adopt") and manager is not None:
                if self._require_api():
                    uid = route[len("/api/users/") : -len("/adopt")]
                    try:
                        self._send_json(200, manager.adopt_preview(uid))
                    except UsersError as ex:
                        self._send_json(ex.code, {"error": str(ex), "problems": ex.problems})
            elif route == "/api/config" and settings is not None:
                if self._require_api():
                    ctx = self._ctx(query)
                    if ctx is not None:
                        self._send_json(200, self._config_payload(ctx[0]))
            elif route == "/api/fs" and settings is not None:
                if self._require_api():
                    path = (query.get("path") or [""])[0] or None
                    try:
                        self._send_json(200, list_dir(path, settings.browse_roots, worker.allowed_extensions))
                    except BrowseError as ex:
                        self._send_json(ex.code, {"error": str(ex)})
            elif route.startswith("/api/geofix") and geofix is not None:
                if self._require_api():
                    self._geofix_get(route, query)
            elif route == "/api/logs" and logs is not None:
                if self._require_api():
                    level = (query.get("level") or ["INFO"])[0]
                    try:
                        limit = max(1, min(2000, int((query.get("limit") or ["300"])[0])))
                        after = max(0, int((query.get("after") or ["0"])[0]))
                    except ValueError:
                        self._send_json(400, {"error": "limit/after must be numbers"})
                        return
                    self._send_json(200, {"entries": logs.entries(level, limit, after)})
            elif route == "/api/logs/download" and logs is not None:
                if self._require_api():
                    stamp = time.strftime("%Y%m%d-%H%M%S")
                    self._send_bytes(
                        200,
                        logs.text().encode(),
                        "text/plain; charset=utf-8",
                        {"Content-Disposition": f'attachment; filename="immich-bridge-{stamp}.log"'},
                    )
            else:
                self._send_json(404, {"error": "not found"})

        # -- PUT / POST ------------------------------------------------------------

        def do_PUT(self) -> None:
            if manager is not None and self.path.startswith("/api/users/"):
                if not self._require_api():
                    return
                body = self._read_json_body()
                if body is None:
                    return
                try:
                    self._send_json(200, manager.update_user(self.path[len("/api/users/") :].strip("/"), body))
                    if scan_now is not None:
                        scan_now()
                except UsersError as ex:
                    self._users_error(ex)
                except Exception:
                    log.exception("users API error")
                    self._send_json(500, {"error": "internal error; see the Logs tab"})
                return
            if self.path == "/api/config" and settings is not None:
                if not self._require_api():
                    return
                body = self._read_json_body()
                if body is None:
                    return
                try:
                    settings.update(body)
                except SettingsError as ex:
                    self._send_json(400, {"error": "; ".join(ex.problems), "problems": ex.problems})
                    return
                except OSError as ex:
                    self._send_json(500, {"error": f"could not save settings: {ex}"})
                    return
                self._send_json(200, self._config_payload())
            else:
                self._send_json(404, {"error": "not found"})

        def do_POST(self) -> None:
            if self.path == "/api/config/reset" and settings is not None:
                if self._require_api():
                    try:
                        settings.reset()
                    except OSError as ex:
                        self._send_json(500, {"error": f"could not save settings: {ex}"})
                        return
                    self._send_json(200, self._config_payload())
                return
            if self.path == "/api/pause" and settings is not None:
                if not self._require_api():
                    return
                body = self._read_json_body()
                if body is None:
                    return
                if not isinstance(body.get("paused"), bool):
                    self._send_json(400, {"error": "send {\"paused\": true} or {\"paused\": false}"})
                    return
                target = body.get("user")
                if target is not None and not isinstance(target, str):
                    self._send_json(400, {"error": "user must be an id"})
                    return
                if target not in (None, "all") and manager is not None:
                    try:
                        info = manager.update_user(target, {"paused": body["paused"]})
                    except UsersError as ex:
                        self._send_json(ex.code, {"error": str(ex), "problems": ex.problems})
                        return
                    log.info("imports for %s %s from the web page", target, "PAUSED" if body["paused"] else "RESUMED")
                    self._send_json(200, {"paused": info["paused"], "queue": info["queue"], "user": target})
                    return
                try:
                    settings.update({"paused": body["paused"]})
                except OSError as ex:
                    self._send_json(500, {"error": f"could not save the pause state: {ex}"})
                    return
                log.info("imports %s from the web page", "PAUSED" if body["paused"] else "RESUMED")
                self._send_json(200, {"paused": cfg.paused, "queue": worker.queue_size})
                return
            if self.path == "/api/reimport":
                if not self._require_api():
                    return
                body = self._read_json_body()
                if body is None:
                    return
                if body.get("confirm") is not True:
                    self._send_json(400, {"error": "send {\"confirm\": true} to forget what was imported and import it all again"})
                    return
                ctx = self._ctx(None, body)
                if ctx is None:
                    return
                forgotten = ctx[0].reimport_everything()
                if scan_now is not None:
                    scan_now()
                self._send_json(200, {"forgotten": forgotten})
                return
            if self.path in ("/api/account/ack", "/api/albums/backfill", "/api/albums/recheck"):
                if not self._require_api():
                    return
                body = self._read_json_body_optional()
                ctx = self._ctx(None, body)
                if ctx is None:
                    return
                w = ctx[0]
                if self.path == "/api/account/ack":
                    w.acknowledge_account()
                    self._send_json(200, {"ok": True})
                elif self.path == "/api/albums/backfill":
                    started = w.start_backfill()
                    self._send_json(200, {"started": started, "albums": w.album_info()})
                else:
                    w.check_album_permission()
                    self._send_json(200, {"albums": w.album_info()})
                return
            if manager is not None and self.path.startswith("/api/users"):
                self._users_post()
                return
            if self.path in ("/api/links/inspect", "/api/links/import") and links is not None:
                self._links_post()
                return
            if self.path.startswith("/api/geofix") and geofix is not None:
                if self._require_api():
                    self._geofix_post()
                return
            if self.path == "/api/scan" and scan_now is not None:
                if self._require_api():
                    scan_now()
                    self._send_json(200, {"ok": True})
                return
            if self.path != "/hook":
                self._send_json(404, {"error": "not found"})
                return
            if cfg.token and not self._authorized():
                time.sleep(0.4)
                self._send_json(401, {"error": "missing or wrong token"})
                return
            length = self._clen()
            if length <= 0 or length > MAX_HOOK_BODY:
                self._send_json(400, {"error": "bad content length"})
                return
            try:
                payload = json.loads(self.rfile.read(length))
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "invalid json"})
                return

            if self._multi() and not cfg.token:
                self._send_json(403, {"error": "with several users /hook needs BRIDGE_TOKEN, so nobody can spoof an uploader"})
                return
            events = payload if isinstance(payload, list) else [payload]
            queued = 0
            for event in events:
                if not isinstance(event, dict):
                    continue
                ap = event.get("ap")
                if not isinstance(ap, str) or not ap:
                    continue
                if ".." in ap.replace("\\", "/").split("/"):
                    log.warning("hook path with '..' refused: %s", ap[:200])
                    continue
                source = event.get("bridge_source")
                if isinstance(source, str) and source:
                    local = cfg.map_source_path(source, ap)
                    if local is None:
                        log.warning("hook from unknown source %r ignored (not in SOURCE_MAPS): %s", source[:40], ap)
                        continue
                else:
                    local = cfg.map_hook_path(ap)
                local = os.path.normpath(local)  # the string checked is exactly the string opened
                login = event.get("user")
                login = login.strip() if isinstance(login, str) and login.strip() not in ("", "*") else None
                if manager is None:
                    if not is_within_dirs(local, cfg.watch_dirs):
                        log.info("hook path outside WATCH_DIRS, ignored: %s", local)
                        continue
                    if worker.enqueue(local, "hook"):
                        queued += 1
                    continue
                if manager.route(local, login) is None:
                    if self._multi():
                        manager.note_unassigned(local, login, source if isinstance(source, str) else None)
                    else:
                        log.info("hook path outside WATCH_DIRS, ignored: %s", local)
                    continue
                if manager.enqueue(local, "hook", login):
                    queued += 1
            self._send_json(200, {"queued": queued})

        # -- people ----------------------------------------------------------------------

        def _read_json_body_optional(self) -> dict | None:
            length = self._clen()
            if length <= 0:
                return {}
            body = self._read_json_body_raw(length)
            return body if isinstance(body, dict) else {}

        def _read_json_body_raw(self, length: int):
            if length > MAX_API_BODY:
                return None
            try:
                return json.loads(self.rfile.read(length))
            except (json.JSONDecodeError, UnicodeDecodeError):
                return None

        def _users_error(self, ex: UsersError) -> None:
            self._send_json(ex.code, {"error": str(ex), "problems": ex.problems})

        def _users_post(self) -> None:
            assert manager is not None
            if not self._require_api():
                return
            body = self._read_json_body()
            if body is None:
                return
            parts = self.path.strip("/").split("/")  # api users [id] [action]
            try:
                if parts == ["api", "users"] and "people_folder" in body:
                    self._send_json(201, manager.add_person_from_folder(body))
                    if scan_now is not None:
                        scan_now()
                elif parts == ["api", "users"]:
                    self._send_json(201, manager.add_user(body))
                    if scan_now is not None:
                        scan_now()
                elif parts == ["api", "users", "check"]:
                    who = body.get("user")
                    if isinstance(body.get("people_folder"), str):
                        info = manager.check_person_key(body["people_folder"], str(body.get("api_key") or ""))
                        self._send_json(200, {"immich_user": info["who"], "album_permission": info["albums"],
                                              "permissions": info["permissions"], "folder_ok": True})
                        return
                    info = manager.check_key(str(body.get("api_key") or ""), ignore_uid=who if isinstance(who, str) else None)
                    self._send_json(200, {"immich_user": info["who"], "album_permission": info["albums"], "permissions": info["permissions"]})
                elif parts == ["api", "users", "ignored", "preview"]:
                    self._send_json(200, manager.ignored_preview(str(body.get("folder") or "")))
                elif parts == ["api", "users", "ignored", "remove"]:
                    if body.get("confirm") is not True or not isinstance(body.get("expected_count"), int):
                        self._send_json(400, {"error": "send {\"confirm\": true, \"expected_count\": <number from the preview>}"})
                        return
                    manager.unignore(str(body.get("folder") or ""), body["expected_count"])
                    self._send_json(200, {"ignored_dirs": list(manager.users.ignored_dirs)})
                    if scan_now is not None:
                        scan_now()
                elif len(parts) == 4 and parts[3] == "adopt":
                    if body.get("confirm") is not True or not isinstance(body.get("expected_count"), int):
                        self._send_json(400, {"error": "send {\"confirm\": true, \"expected_count\": <number from the preview>}"})
                        return
                    self._send_json(200, manager.adopt(parts[2], body["expected_count"]))
                    if scan_now is not None:
                        scan_now()
                else:
                    self._send_json(404, {"error": "not found"})
            except UsersError as ex:
                self._users_error(ex)
            except Exception:
                log.exception("users API error")
                self._send_json(500, {"error": "internal error; see the Logs tab"})

        def do_DELETE(self) -> None:
            if manager is None or not self.path.startswith("/api/users/"):
                self._send_json(404, {"error": "not found"})
                return
            if not self._require_api():
                return
            body = self._read_json_body()
            if body is None:
                return
            uid = self.path[len("/api/users/") :].strip("/")
            try:
                self._send_json(200, manager.remove_user(uid, str(body.get("confirm") or "")))
            except UsersError as ex:
                self._users_error(ex)
            except Exception:
                log.exception("users API error")
                self._send_json(500, {"error": "internal error; see the Logs tab"})

    return Handler


def serve(
    cfg: Config,
    state: StateStore,
    worker: ImportWorker,
    settings: SettingsStore | None = None,
    logs: RingLogHandler | None = None,
    scan_now: Callable[[], None] | None = None,
    manager: UserManager | None = None,
    geofix: GeoFix | None = None,
    links: LinkImports | None = None,
) -> ThreadingHTTPServer:
    handler = make_handler(cfg, state, worker, settings, logs, scan_now, manager, geofix, links)
    httpd = ThreadingHTTPServer((cfg.bind_host, cfg.bind_port), handler)
    log.info("listening on %s:%d", cfg.bind_host, cfg.bind_port)
    return httpd
