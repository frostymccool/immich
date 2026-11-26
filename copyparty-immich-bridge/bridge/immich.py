"""Minimal Immich API client for the bridge (requests-based).

Endpoints used (verified against the immich server source):
  GET  /api/server/media-types      supported image/video/sidecar extensions
  POST /api/assets/bulk-upload-check   SHA-1 duplicate pre-check (hex or base64)
  POST /api/assets                  multipart upload; 200 = duplicate, 201 = created
  GET  /api/albums, POST /api/albums, PUT /api/albums/{id}/assets   optional album
"""

from __future__ import annotations

import hashlib
import logging
import os
import uuid
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone

import requests

log = logging.getLogger("bridge.immich")

# What the API key needs for albums (Immich permission names, from its OpenAPI spec). "all" covers them.
ALBUM_PERMISSIONS = ("album.read", "album.create", "albumAsset.create")
# Without these the bridge cannot work at all (names checked against Immich's server/src/enum.ts and controllers):
# GET /users/me needs user.read; POST /assets and /assets/bulk-upload-check need asset.upload.
REQUIRED_PERMISSIONS = {
    "user.read": "to tell which Immich account the key belongs to",
    "asset.upload": "to upload files and check for duplicates",
}
ALBUM_PERMISSION_WHY = {
    "album.read": "to find an existing album",
    "album.create": "to create folder albums",
    "albumAsset.create": "to add files to an album",
}

# Fallback when Immich is unreachable at startup and INCLUDE_EXTENSIONS is not
# set. Conservative subset of Immich's supported media types.
DEFAULT_EXTENSIONS = {
    "jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff",
    "heic", "heif", "avif", "jxl",
    "dng", "raw", "arw", "cr2", "cr3", "nef", "orf", "rw2", "raf",
    "mp4", "mov", "m4v", "mkv", "webm", "avi", "3gp", "mts", "m2ts", "wmv",
}


class ImmichError(Exception):
    pass


@dataclass
class UploadOutcome:
    # "imported" when the asset was newly created, "duplicate" when Immich
    # already had this content (either pre-checked or replied 200/duplicate).
    status: str
    asset_id: str | None


def sha1_hex(path: str, chunk_size: int = 1024 * 1024) -> str:
    """Streaming SHA-1 — files can be multi-GB videos."""
    digest = hashlib.sha1()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(chunk_size)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


class _MultipartBody:
    """Streams a multipart/form-data upload from disk with a known length, reporting bytes sent."""

    def __init__(self, fields: dict[str, str], filename: str, path: str, progress, sidecar: bytes | None = None):
        self.boundary = uuid.uuid4().hex
        head = "".join(
            f'--{self.boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n' for k, v in fields.items()
        )
        quoted = filename.replace("\\", "\\\\").replace('"', "%22").replace("\r", "").replace("\n", "")
        raw_head = head.encode("utf-8")
        if sidecar is not None:
            # a small XMP sidecar (location / time zone chosen on the Fix locations tab) travels with the file
            raw_head += (f'--{self.boundary}\r\nContent-Disposition: form-data; name="sidecarData"; filename="{quoted}.xmp"\r\n'
                         "Content-Type: application/xml\r\n\r\n").encode("utf-8") + sidecar + b"\r\n"
        head = (
            f'--{self.boundary}\r\nContent-Disposition: form-data; name="assetData"; filename="{quoted}"\r\n'
            "Content-Type: application/octet-stream\r\n\r\n"
        )
        self._head = raw_head + head.encode("utf-8")
        self._tail = f"\r\n--{self.boundary}--\r\n".encode()
        self._file_size = os.path.getsize(path)
        self._fh = open(path, "rb")
        self._parts_done = 0  # 0 head, 1 file, 2 tail, 3 finished
        self._progress = progress
        self._sent = 0
        self._total = len(self._head) + self._file_size + len(self._tail)

    def __len__(self) -> int:
        return self._total

    def read(self, n: int = 65536) -> bytes:
        if self._parts_done == 0:
            self._parts_done = 1
            chunk = self._head
        elif self._parts_done == 1:
            chunk = self._fh.read(n)
            if not chunk:
                self._parts_done = 2
                chunk = self._tail
        else:
            self._parts_done = 3
            chunk = b""
        self._sent += len(chunk)
        if self._progress is not None and chunk:
            self._progress(min(self._sent, self._total), self._total)
        return chunk

    def __iter__(self):
        while True:
            chunk = self.read()
            if not chunk:
                return
            yield chunk

    def close(self) -> None:
        self._fh.close()


class ImmichClient:
    def __init__(self, base_url: str, api_key: str, device_id: str, verify_tls: bool = True, timeout: int = 30, upload_timeout: int = 1800):
        self._base = base_url.rstrip("/")
        self._device_id = device_id
        self._timeout = timeout
        self._upload_timeout = upload_timeout
        self._session = requests.Session()
        self._session.verify = verify_tls
        self._session.headers.update({"x-api-key": api_key, "Accept": "application/json"})
        # album name -> id, so a folder-named album is looked up/created once, not per file
        self._album_ids: dict[str, str] = {}
        self._album_lock = threading.Lock()
        # what the page shows so a silent failure (usually a key without album permissions) is visible
        self.album_stats: dict = {"added": 0, "failed": 0, "last_error": None, "last_error_at": None}

    def close(self) -> None:
        self._session.close()

    # -- server ---------------------------------------------------------------

    def supported_extensions(self) -> set[str]:
        """Image + video extensions the server ingests (without leading dots).

        Sidecar types are excluded — they cannot be uploaded standalone.
        Tries the current route first, then the legacy /server-info one.
        """
        last_error: Exception | None = None
        for route in ("/api/server/media-types", "/api/server-info/media-types"):
            try:
                resp = self._session.get(self._base + route, timeout=self._timeout)
                if resp.status_code == 404:
                    continue
                resp.raise_for_status()
                body = resp.json()
                exts = {e.lstrip(".").lower() for e in body.get("image", []) + body.get("video", [])}
                if exts:
                    return exts
            except requests.RequestException as ex:
                last_error = ex
        raise ImmichError(f"cannot fetch supported media types: {last_error}")

    # -- assets ---------------------------------------------------------------

    def find_by_checksum(self, sha1_hex_digest: str, ref_id: str) -> str | None:
        """Returns the existing asset id (or 'present') when the content is
        already in Immich, else None. The endpoint accepts hex or base64."""
        resp = self._session.post(
            self._base + "/api/assets/bulk-upload-check",
            json={"assets": [{"id": ref_id, "checksum": sha1_hex_digest}]},
            timeout=self._timeout,
        )
        resp.raise_for_status()
        results = resp.json().get("results", [])
        if not results:
            return None
        first = results[0]
        if first.get("action") == "reject":
            return first.get("assetId") or "present"
        return None

    def upload(self, path: str, sha1_hex_digest: str, progress=None, sidecar: bytes | None = None) -> UploadOutcome:
        """Uploads one file. Immich replies 201 (created) or 200 (duplicate)."""
        stat = os.stat(path)
        mtime_iso = datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).isoformat()
        filename = os.path.basename(path)
        data = {
            # deviceAssetId/deviceId are required by stable (v2) servers and
            # harmless on newer ones.
            "deviceAssetId": f"{path}-{stat.st_size}",
            "deviceId": self._device_id,
            "fileCreatedAt": mtime_iso,
            "fileModifiedAt": mtime_iso,
            "filename": filename,
            "isFavorite": "false",
        }
        if sidecar is not None:
            # Immich checks every part's type against `filename` when it is set, so "x.MP4" would refuse the .xmp;
            # without it each part is named by its own filename, which carries the same name for the file
            del data["filename"]
        body = _MultipartBody(data, filename, path, progress, sidecar)
        try:
            resp = self._session.post(
                self._base + "/api/assets",
                data=body,
                headers={
                    "x-immich-checksum": sha1_hex_digest,
                    "Content-Type": f"multipart/form-data; boundary={body.boundary}",
                },
                # Big videos over a LAN need a long wait for Immich's reply, but not forever: a stalled
                # upload must fail (and be retried) instead of blocking the queue.
                timeout=(self._timeout, self._upload_timeout),
            )
        finally:
            body.close()
        if resp.status_code not in (200, 201):
            raise ImmichError(f"upload failed: HTTP {resp.status_code}: {resp.text[:300]}")
        body = resp.json()
        asset_id = body.get("id")
        duplicate = resp.status_code == 200 or body.get("status") == "duplicate"
        return UploadOutcome(status="duplicate" if duplicate else "imported", asset_id=asset_id)

    # -- nearby photos (Fix locations tab) --------------------------------------

    def _explain(self, resp, what: str) -> None:
        if resp.status_code == 401:
            raise ImmichError("Immich says the API key is not valid")
        if resp.status_code == 403:
            raise ImmichError(f"the API key lacks the permission needed to {what}; in Immich create a key with all "
                              "permissions (Account Settings > API Keys) or add that permission")
        if resp.status_code != 200:
            raise ImmichError(f"Immich answered HTTP {resp.status_code}: {resp.text[:200]}")

    def stacked_asset_ids(self) -> set[str]:
        """Every asset already in a stack (GET /stacks, permission stack.read): search results do not say."""
        resp = self._session.get(self._base + "/api/stacks", timeout=self._timeout)
        self._explain(resp, "read stacks (stack.read)")
        return {a["id"] for s in resp.json() for a in s.get("assets") or []}

    def create_stack(self, asset_ids: list[str]) -> dict:
        """POST /stacks (permissions stack.create + asset.update): the first id becomes the cover."""
        resp = self._session.post(self._base + "/api/stacks", json={"assetIds": asset_ids}, timeout=self._timeout)
        if resp.status_code in (200, 201):
            return resp.json()
        self._explain(resp, "stack photos (stack.create, asset.update)")
        raise ImmichError(f"Immich answered HTTP {resp.status_code}: {resp.text[:200]}")  # 2xx other than 200/201

    def search_metadata(self, body: dict) -> dict:
        """POST /search/metadata (permission asset.read): the account's assets in a time window, with EXIF."""
        resp = self._session.post(self._base + "/api/search/metadata", json=body, timeout=self._timeout)
        self._explain(resp, "look up photos (asset.read)")
        return resp.json()

    def ping(self) -> float | None:
        """Seconds Immich took to answer GET /server/ping (no permission needed), or None when it did not."""
        start = time.monotonic()
        try:
            resp = self._session.get(self._base + "/api/server/ping", timeout=(5, 20))
        except requests.RequestException:
            return None
        return time.monotonic() - start if resp.status_code == 200 else None

    def get_asset(self, asset_id: str) -> dict:
        """GET /assets/{id} (permission asset.read), with its EXIF."""
        resp = self._session.get(f"{self._base}/api/assets/{asset_id}", timeout=self._timeout)
        self._explain(resp, "read a photo (asset.read)")
        return resp.json()

    def update_asset(self, asset_id: str, fields: dict) -> None:
        """PUT /assets/{id} (permission asset.update): place / time in Immich's metadata; the original is not touched."""
        resp = self._session.put(f"{self._base}/api/assets/{asset_id}", json=fields, timeout=self._timeout)
        self._explain(resp, "update a photo (asset.update)")

    def search_places(self, name: str) -> list[dict]:
        """GET /search/places (permission asset.read): Immich's own place-name index."""
        resp = self._session.get(self._base + "/api/search/places", params={"name": name}, timeout=self._timeout)
        self._explain(resp, "search places (asset.read)")
        out = resp.json()
        return out if isinstance(out, list) else []

    def thumbnail(self, asset_id: str, size: str = "thumbnail") -> tuple[bytes, str]:
        """GET /assets/{id}/thumbnail (permission asset.view); size 'thumbnail' (small) or 'preview' (large)."""
        resp = self._session.get(self._base + f"/api/assets/{asset_id}/thumbnail", params={"size": size}, timeout=self._timeout)
        self._explain(resp, "show photos (asset.view)")
        return resp.content, resp.headers.get("Content-Type", "image/webp")

    def download_original(self, asset_id: str, dest: str, max_bytes: int) -> str:
        """GET /assets/{id}/original (permission asset.download) streamed into `dest`; returns the asset's mime type.
        Refuses (ImmichError) a file larger than max_bytes rather than filling the disk."""
        with self._session.get(self._base + f"/api/assets/{asset_id}/original", stream=True, timeout=self._timeout) as resp:
            self._explain(resp, "download originals (asset.download)")
            size = 0
            with open(dest, "wb") as fh:
                for chunk in resp.iter_content(1 << 20):
                    size += len(chunk)
                    if size > max_bytes:
                        raise ImmichError(f"the original is larger than {max_bytes >> 20} MB")
                    fh.write(chunk)
            return resp.headers.get("Content-Type", "")

    # -- albums ---------------------------------------------------------------

    def album_permission_status(self) -> dict:
        """Does this API key have the album permissions? {'ok': True|False|None, 'missing': [...]};
        None = could not tell (GET /api/api-keys/me needs no permission, so this only fails on network trouble)."""
        try:
            resp = self._session.get(self._base + "/api/api-keys/me", timeout=self._timeout)
            resp.raise_for_status()
            granted = set(resp.json().get("permissions") or [])
        except (requests.RequestException, ValueError, AttributeError):
            return {"ok": None, "missing": []}
        if "all" in granted:
            return {"ok": True, "missing": []}
        missing = [p for p in ALBUM_PERMISSIONS if p not in granted]
        return {"ok": not missing, "missing": missing}

    def key_permissions(self) -> tuple[set[str] | None, str | None]:
        """What this API key may do: (granted permissions, None) or (None, reason). GET /api-keys/me needs no
        permission at all, so it works even for a key that cannot do anything else."""
        try:
            resp = self._session.get(self._base + "/api/api-keys/me", timeout=self._timeout)
        except requests.RequestException as ex:
            return None, f"Could not reach Immich at {self._base} ({type(ex).__name__}); is the address right and Immich running?"
        if resp.status_code == 401:
            return None, "Immich says that API key is not valid. Check it was copied completely and was created on THIS Immich server."
        if resp.status_code != 200:
            return None, f"Immich answered HTTP {resp.status_code} when asked what the key may do."
        try:
            return set(resp.json().get("permissions") or []), None
        except (ValueError, AttributeError):
            return None, "Immich's answer was not understood (is the address really Immich?)."

    def whoami_ex(self) -> tuple[dict | None, str | None]:
        """Like whoami(), but says WHY it failed, in plain words, when it did: (account, None) or (None, reason).
        Immich answers GET /users/me only for a key with the user.read permission (or 'all')."""
        try:
            resp = self._session.get(self._base + "/api/users/me", timeout=self._timeout)
        except requests.RequestException as ex:
            return None, f"Could not reach Immich at {self._base} ({type(ex).__name__}); is the address right and Immich running?"
        if resp.status_code == 401:
            return None, "Immich says that API key is not valid. Check it was copied completely and was created on THIS Immich server."
        if resp.status_code == 403:
            return None, ("That key is valid, but it was created without the 'user.read' permission, which the bridge needs "
                          "to tell whose account it is. In Immich create a new key (Account Settings > API Keys) with all permissions.")
        if resp.status_code != 200:
            return None, f"Immich answered HTTP {resp.status_code} when asked who the key belongs to."
        try:
            body = resp.json()
            return {
                "id": str(body.get("id") or ""),
                "name": str(body.get("name") or ""),
                "email": str(body.get("email") or ""),
            }, None
        except (ValueError, AttributeError):
            return None, "Immich's answer was not understood (is the address really Immich?)."

    def whoami(self) -> dict | None:
        """The Immich account this API key belongs to: {'id', 'name', 'email'} or None. Everything the bridge
        imports, and every album it creates, belongs to THIS account - which may not be the one you log in
        with, and then you would not see any of it."""
        return self.whoami_ex()[0]

    def known_albums(self) -> dict[str, str]:
        """album name -> Immich album id for the albums this bridge has used since it started."""
        with self._album_lock:
            return dict(self._album_ids)

    def _album_result(self, error: str | None) -> None:
        with self._album_lock:
            if error is None:
                self.album_stats["added"] += 1
            else:
                self.album_stats["failed"] += 1
                self.album_stats["last_error"] = error
                self.album_stats["last_error_at"] = time.time()

    def add_to_album(self, album_name: str, asset_id: str) -> bool:
        """Adds an asset to the named album, creating the album on first use.
        Best-effort: errors are logged and counted (the web page shows them), never raised.
        Returns True when the asset is in the album afterwards.

        Immich answers 200 with a per-asset result, so that list is checked too ("duplicate" = it was
        already in the album, fine). If the cached album was deleted in Immich since, the first attempt
        fails with 400/404; the cache entry is dropped and the album is looked up / created once more."""
        for attempt in (1, 2):
            try:
                album_id = self._get_or_create_album(album_name)
                resp = self._session.put(
                    f"{self._base}/api/albums/{album_id}/assets",
                    json={"ids": [asset_id]},
                    timeout=self._timeout,
                )
                resp.raise_for_status()
                try:
                    results = resp.json()
                except ValueError:
                    results = []
                bad = [r for r in results if isinstance(r, dict) and not r.get("success") and r.get("error") != "duplicate"]
                if bad:
                    reason = bad[0].get("error") or bad[0].get("errorMessage") or "unknown"
                    msg = f"Immich refused to add the asset to {album_name!r}: {reason}"
                    log.warning("album add failed for %s: %s", asset_id, msg)
                    self._album_result(msg)
                    return False
                self._album_result(None)
                return True
            except requests.HTTPError as ex:
                status = ex.response.status_code if ex.response is not None else 0
                if attempt == 1 and status in (400, 404):
                    with self._album_lock:
                        self._album_ids.pop(album_name, None)
                    continue
                detail = (ex.response.text or "")[:200].strip() if ex.response is not None else ""
                msg = f"HTTP {status} for album {album_name!r}" + (f": {detail}" if detail else "")
                log.warning("album add failed for %s: %s", asset_id, msg)
                self._album_result(msg)
                return False
            except requests.RequestException as ex:
                log.warning("album add failed for %s -> %r: %s", asset_id, album_name, ex)
                self._album_result(f"{album_name!r}: {ex}")
                return False
        return False

    def _get_or_create_album(self, album_name: str) -> str:
        with self._album_lock:
            cached = self._album_ids.get(album_name)
            if cached:
                return cached
            resp = self._session.get(self._base + "/api/albums", timeout=self._timeout)
            resp.raise_for_status()
            for album in resp.json():
                if album.get("albumName") == album_name:
                    self._album_ids[album_name] = album["id"]
                    return album["id"]
            resp = self._session.post(
                self._base + "/api/albums",
                json={"albumName": album_name},
                timeout=self._timeout,
            )
            resp.raise_for_status()
            self._album_ids[album_name] = resp.json()["id"]
            log.info("created Immich album %r", album_name)
            return self._album_ids[album_name]
