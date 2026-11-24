"""A minimal in-process stub of the Immich API endpoints the bridge uses."""

from __future__ import annotations

import json
import re
import urllib.parse
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
        # Fix locations: the account's existing photos (search), Immich's place index, one tiny PNG as every thumbnail
        self.assets: list[dict] = []
        self.searches: list[dict] = []
        self.paths: list[str] = []  # every GET path, query included
        self.originals: dict[str, tuple[bytes, str]] = {}  # asset id -> (bytes, mime) for /original
        self.no_preview: set[str] = set()  # asset ids whose /thumbnail answers 404 "Asset media not found" (real Immich)
        self.forbid_search = False
        self.places: list[dict] = []
        self.thumbnail = bytes.fromhex(
            "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c6360f8cfc0000003010100c9fe92ef0000000049454e44ae426082")
        self._album_seq = 0
        self.user_name = "Test User"
        self.user_id = "user-1"
        self.user_email = "test@example.test"
        self.key_permissions: list[str] = ["all"]
        self.api_key_status = 200  # status of GET /api-keys/me (401 = key not valid)
        self.users_me_status = 200  # e.g. 401 (bad key) or 403 (key without user.read)
        self.forbid_albums = False  # every album call answers 403 (a key without album permissions)
        self.album_item_error: str | None = None  # PUT answers 200 but with a per-asset error
        self.album_fail_ids: set[str] = set()
        self.removed_albums: set[str] = set()
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
                stub.paths.append(self.path)
                if self.path == stub.media_types_route:
                    self._json(200, {"image": [".jpg", ".png", ".heic"], "video": [".mp4"], "sidecar": [".xmp"]})
                elif self.path == "/api/users/me" and stub.users_me_status != 200:
                    self._json(stub.users_me_status, {"message": "nope"})
                elif self.path == "/api/users/me":
                    self._json(200, {"id": stub.user_id, "name": stub.user_name, "email": stub.user_email})
                elif self.path == "/api/api-keys/me" and stub.api_key_status != 200:
                    self._json(stub.api_key_status, {"message": "nope"})
                elif self.path == "/api/api-keys/me":
                    self._json(200, {"id": "key-1", "name": "bridge", "permissions": stub.key_permissions})
                elif self.path.startswith("/api/search/places"):
                    name = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("name", [""])[0].lower()
                    self._json(200, [p for p in stub.places if name in p["name"].lower()])
                elif re.fullmatch(r"/api/assets/[^/]+", self.path) and any(a["id"] == self.path.split("/")[3] for a in stub.assets):
                    self._json(200, next(a for a in stub.assets if a["id"] == self.path.split("/")[3]))
                elif re.fullmatch(r"/api/assets/[^/]+/thumbnail(\?.*)?", self.path) and self.path.split("/")[3] in stub.no_preview:
                    self._json(404, {"message": "Asset media not found"})
                elif re.fullmatch(r"/api/assets/[^/]+/original", self.path) and self.path.split("/")[3] in stub.originals:
                    data, mime = stub.originals[self.path.split("/")[3]]
                    self.send_response(200)
                    self.send_header("Content-Type", mime)
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                elif re.fullmatch(r"/api/assets/[^/]+/thumbnail(\?.*)?", self.path):
                    data = stub.thumbnail
                    self.send_response(200)
                    self.send_header("Content-Type", "image/png")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                elif self.path == "/api/albums" and stub.forbid_albums:
                    self._json(403, {"message": "Missing required permission: album.read"})
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
                    # like Immich: a `filename` field names every part, so a sidecar under "x.MP4" is refused
                    named = re.search(rb'name="filename"\r\n\r\n([^\r]*)', body)
                    if b'name="sidecarData"' in body and named and not named.group(1).lower().endswith(b".xmp"):
                        self._json(400, {"message": f"Unsupported file type {named.group(1).decode()}"})
                        return
                    existing = stub.known_checksums.get(checksum)
                    if existing:
                        self._json(200, {"id": existing, "status": "duplicate"})
                        return
                    stub._counter += 1
                    asset_id = f"asset-{stub._counter}"
                    if checksum:
                        stub.known_checksums[checksum] = asset_id
                    sidecar = None
                    mark = body.find(b'name="sidecarData"')
                    if mark >= 0:  # the XMP part sent next to the file (Fix locations)
                        start = body.find(b"\r\n\r\n", mark) + 4
                        sidecar = body[start : body.find(b"\r\n--", start)].decode("utf-8")
                    stub.uploads.append({"checksum": checksum, "raw_len": len(body), "sidecar": sidecar})
                    self._json(201, {"id": asset_id, "status": "created"})
                elif self.path == "/api/search/metadata":
                    if stub.forbid_search:
                        self._json(403, {"message": "Missing required permission: asset.read"})
                        return
                    q = json.loads(body)
                    stub.searches.append(q)
                    hits = [a for a in stub.assets if q["takenAfter"][:19] <= a["fileCreatedAt"][:19] <= q["takenBefore"][:19]]
                    size, page = int(q.get("size", 250)), int(q.get("page", 1))
                    part = hits[(page - 1) * size : page * size]
                    self._json(200, {"assets": {"items": part, "total": len(part), "count": len(part),
                                                "nextPage": str(page + 1) if page * size < len(hits) else None}})
                elif self.path == "/api/albums" and stub.forbid_albums:
                    self._json(403, {"message": "Missing required permission: album.create"})
                elif self.path == "/api/albums":
                    name = json.loads(body)["albumName"]
                    stub._album_seq += 1
                    album = {"id": f"album-{stub._album_seq}", "albumName": name}
                    stub.albums.append(album)
                    stub.album_assets[album["id"]] = []
                    self._json(201, album)
                else:
                    self._json(404, {"error": "not found"})

            def do_PUT(self):
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                m = re.fullmatch(r"/api/albums/([^/]+)/assets", self.path)
                one = re.fullmatch(r"/api/assets/([^/]+)", self.path)
                if one:
                    fields = json.loads(body)
                    stub.__dict__.setdefault("asset_updates", []).append((one.group(1), fields))
                    self._json(200, {"id": one.group(1)})
                elif m and m.group(1) in stub.removed_albums:
                    self._json(404, {"message": "Not found or no album.update access"})
                elif m and stub.forbid_albums:
                    self._json(403, {"message": "Missing required permission: albumAsset.create"})
                elif m:
                    ids = json.loads(body)["ids"]
                    if stub.album_item_error:
                        self._json(200, [{"id": i, "success": False, "error": stub.album_item_error} for i in ids])
                        return
                    already = stub.album_assets.setdefault(m.group(1), [])
                    out = []
                    for i in ids:
                        if i in already:
                            out.append({"id": i, "success": False, "error": "duplicate"})
                        else:
                            already.append(i)
                            out.append({"id": i, "success": True})
                    self._json(200, out)
                else:
                    self._json(404, {"error": "not found"})

        self._httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self._httpd.server_port}"
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)

    def remove_album(self, name: str) -> None:
        """Simulates the user deleting an album in Immich."""
        for album in list(self.albums):
            if album["albumName"] == name:
                self.albums.remove(album)
                self.removed_albums.add(album["id"])

    def __enter__(self) -> "StubImmich":
        self._thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self._httpd.shutdown()
        self._httpd.server_close()
