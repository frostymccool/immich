"""HTTP endpoints: the copyparty hook receiver plus status/health.

POST /hook    body = the JSON copyparty's xau hook produced (single object),
              or a JSON list (xiu batch mode). Returns {"queued": n}.
GET  /status  state-DB counters, queue size, recent items.
GET  /healthz liveness probe.
"""

from __future__ import annotations

import json
import logging
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from bridge import __version__
from bridge.config import Config
from bridge.state import StateStore
from bridge.worker import ImportWorker

log = logging.getLogger("bridge.server")

MAX_HOOK_BODY = 4 * 1024 * 1024


def make_handler(cfg: Config, state: StateStore, worker: ImportWorker) -> type[BaseHTTPRequestHandler]:
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

        def do_GET(self) -> None:
            if self.path == "/healthz":
                self._send_json(200, {"ok": True, "version": __version__})
            elif self.path == "/status":
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
                self._send_json(200, {"counts": state.counts(), "queue": worker.queue_size, "recent": recent})
            else:
                self._send_json(404, {"error": "not found"})

        def do_POST(self) -> None:
            if self.path != "/hook":
                self._send_json(404, {"error": "not found"})
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
                if worker.enqueue(local, "hook"):
                    queued += 1
            self._send_json(200, {"queued": queued})

    return Handler


def serve(cfg: Config, state: StateStore, worker: ImportWorker) -> ThreadingHTTPServer:
    httpd = ThreadingHTTPServer((cfg.bind_host, cfg.bind_port), make_handler(cfg, state, worker))
    log.info("listening on %s:%d", cfg.bind_host, cfg.bind_port)
    return httpd
