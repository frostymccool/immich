"""A minimal in-process stub of the Immich API endpoints the bridge uses."""

from __future__ import annotations

import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class StubImmich:
    """known_checksums: hex sha1 -> asset id. Uploads register their checksum
    (from the x-immich-checksum header) and return 201; an upload whose
    checksum is already known returns 200/duplicate like the real server."""

    def __init__(self, media_types_route: str = "/api/server/media-types"):
        self.known_checksums: dict[str, str] = {}
        self.uploads: list[dict] = []
        self.albums: list[dict] = []
        self.album_assets: dict[str, list[str]] = {}
        self.media_types_route = media_types_route
        self._counter = 0

        stub = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _json(self, code: int, payload) -> None:
                body = json.dumps(payload).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path == stub.media_types_route:
                    self._json(200, {"image": [".jpg", ".png", ".heic"], "video": [".mp4"], "sidecar": [".xmp"]})
                elif self.path == "/api/albums":
                    self._json(200, stub.albums)
                else:
                    self._json(404, {"error": "not found"})

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                if self.path == "/api/assets/bulk-upload-check":
                    assets = json.loads(body)["assets"]
                    results = []
                    for a in assets:
                        asset_id = stub.known_checksums.get(a["checksum"])
                        if asset_id:
                            results.append(
                                {"id": a["id"], "action": "reject", "reason": "duplicate", "assetId": asset_id}
                            )
                        else:
                            results.append({"id": a["id"], "action": "accept"})
                    self._json(200, {"results": results})
                elif self.path == "/api/assets":
                    checksum = self.headers.get("x-immich-checksum", "")
                    existing = stub.known_checksums.get(checksum)
                    if existing:
                        self._json(200, {"id": existing, "status": "duplicate"})
                        return
                    stub._counter += 1
                    asset_id = f"asset-{stub._counter}"
                    if checksum:
                        stub.known_checksums[checksum] = asset_id
                    stub.uploads.append({"checksum": checksum, "raw_len": len(body)})
                    self._json(201, {"id": asset_id, "status": "created"})
                elif self.path == "/api/albums":
                    name = json.loads(body)["albumName"]
                    album = {"id": f"album-{len(stub.albums) + 1}", "albumName": name}
                    stub.albums.append(album)
                    stub.album_assets[album["id"]] = []
                    self._json(201, album)
                else:
                    self._json(404, {"error": "not found"})

            def do_PUT(self):
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                m = re.fullmatch(r"/api/albums/([^/]+)/assets", self.path)
                if m:
                    ids = json.loads(body)["ids"]
                    stub.album_assets.setdefault(m.group(1), []).extend(ids)
                    self._json(200, [{"id": i, "success": True} for i in ids])
                else:
                    self._json(404, {"error": "not found"})

        self._httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self._httpd.server_port}"
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)

    def __enter__(self) -> "StubImmich":
        self._thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self._httpd.shutdown()
        self._httpd.server_close()
