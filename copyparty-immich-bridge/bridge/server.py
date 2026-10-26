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
from bridge.scanner import is_within_dirs
from bridge.settings import SettingsError, SettingsStore
from bridge.state import StateStore
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

        def _read_json_body(self) -> dict | None:
            length = int(self.headers.get("Content-Length") or 0)
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

        def _config_payload(self) -> dict:
            assert settings is not None
            return {
                "values": settings.values(),
                "defaults": settings.defaults(),
                "overridden": settings.overridden(),
                "readonly": {
                    "version": __version__,
                    "immich_url": cfg.immich_url,
                    "api_key_set": bool(cfg.api_key),
                    "bind_port": cfg.bind_port,
                    "workers": cfg.workers,
                    "device_id": cfg.device_id,
                    "state_db": cfg.state_db,
                    "settings_file": cfg.settings_file,
                    "uptime_seconds": int(time.time() - STARTED_AT),
                },
                "browse_roots": settings.browse_roots,
            }

        # -- GET -------------------------------------------------------------------

        def do_GET(self) -> None:
            url = urlparse(self.path)
            route = url.path
            query = parse_qs(url.query)

            if route in ("/", "/ui", "/index.html"):
                self._send_bytes(200, _load_ui(), "text/html; charset=utf-8")
            elif route == "/healthz":
                self._send_json(200, {"ok": True, "version": __version__})
            elif route == "/status":
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
                        "watch_dirs": cfg.watch_dirs,
                        "priority_dirs": cfg.priority_dirs,
                        "albums": worker.album_info(),
                        "recent": recent,
                    },
                )
            elif route == "/api/config" and settings is not None:
                if self._require_api():
                    self._send_json(200, self._config_payload())
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
                try:
                    settings.update({"paused": body["paused"]})
                except OSError as ex:
                    self._send_json(500, {"error": f"could not save the pause state: {ex}"})
                    return
                log.info("imports %s from the web page", "PAUSED" if body["paused"] else "RESUMED")
                self._send_json(200, {"paused": cfg.paused, "queue": worker.queue_size})
                return
            if self.path == "/api/albums/backfill":
                if self._require_api():
                    started = worker.start_backfill()
                    self._send_json(200, {"started": started, "albums": worker.album_info()})
                return
            if self.path == "/api/albums/recheck":
                if self._require_api():
                    worker.check_album_permission()
                    self._send_json(200, {"albums": worker.album_info()})
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
                self._send_json(401, {"error": "missing or wrong token"})
                return
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > MAX_HOOK_BODY:
                self._send_json(400, {"error": "bad content length"})
                return
            try:
                payload = json.loads(self.rfile.read(length))
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "invalid json"})
                return

            events = payload if isinstance(payload, list) else [payload]
            queued = 0
            for event in events:
                if not isinstance(event, dict):
                    continue
                ap = event.get("ap")
                if not isinstance(ap, str) or not ap:
                    continue
                local = cfg.map_hook_path(ap)
                if not is_within_dirs(local, cfg.watch_dirs):
                    log.info("hook path outside WATCH_DIRS, ignored: %s", local)
                    continue
                if worker.enqueue(local, "hook"):
                    queued += 1
            self._send_json(200, {"queued": queued})

    return Handler


def serve(
    cfg: Config,
    state: StateStore,
    worker: ImportWorker,
    settings: SettingsStore | None = None,
    logs: RingLogHandler | None = None,
    scan_now: Callable[[], None] | None = None,
) -> ThreadingHTTPServer:
    handler = make_handler(cfg, state, worker, settings, logs, scan_now)
    httpd = ThreadingHTTPServer((cfg.bind_host, cfg.bind_port), handler)
    log.info("listening on %s:%d", cfg.bind_host, cfg.bind_port)
    return httpd
