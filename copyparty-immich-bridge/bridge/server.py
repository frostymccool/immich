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

import hmac
import json
import logging
import os
import time
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from bridge import __version__
from bridge.browse import BrowseError, list_dir
from bridge.config import Config
from bridge.logbuffer import RingLogHandler
from bridge.manager import UserManager
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


def make_handler(
    cfg: Config,
    state: StateStore,
    worker: ImportWorker,
    settings: SettingsStore | None = None,
    logs: RingLogHandler | None = None,
    scan_now: Callable[[], None] | None = None,
    manager: UserManager | None = None,
) -> type[BaseHTTPRequestHandler]:
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

        def _send_status(self, query: dict) -> None:
            """/status is open (the phone app reads it): counters, queue, no names, no keys. Without ?user= it
            is the total over everybody, which for a single-user install is exactly the old output."""
            if (query.get("user") or [None])[0] is not None or self._multi():
                one = (query.get("user") or [None])[0]
                if one is not None:
                    if not self._require_api():  # per-person detail (paths, errors) is not for the open endpoint
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
                        "priority_dirs": cfg.priority_dirs if one in (None, MAIN_ID) else [],
                        "albums": parts[0][0].album_info() if one is not None else worker.album_info(),
                        "recent": recent,
                        "users": len(parts) if one is None else 1,
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
                    "watch_dirs": cfg.watch_dirs,
                    "priority_dirs": cfg.priority_dirs,
                    "albums": worker.album_info(),
                    "recent": recent,
                },
            )

        # -- GET -------------------------------------------------------------------

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
            elif route == "/api/users" and manager is not None:
                if self._require_api():
                    self._send_json(200, manager.describe_all())
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
                if parts == ["api", "users"]:
                    self._send_json(201, manager.add_user(body))
                    if scan_now is not None:
                        scan_now()
                elif parts == ["api", "users", "check"]:
                    who = body.get("user")
                    info = manager.check_key(str(body.get("api_key") or ""), ignore_uid=who if isinstance(who, str) else None)
                    self._send_json(200, {"immich_user": info["who"], "album_permission": info["albums"]})
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
) -> ThreadingHTTPServer:
    handler = make_handler(cfg, state, worker, settings, logs, scan_now, manager)
    httpd = ThreadingHTTPServer((cfg.bind_host, cfg.bind_port), handler)
    log.info("listening on %s:%d", cfg.bind_host, cfg.bind_port)
    return httpd
