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
from dataclasses import dataclass
from datetime import datetime, timezone

import requests

log = logging.getLogger("bridge.immich")

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


class ImmichClient:
    def __init__(self, base_url: str, api_key: str, device_id: str, verify_tls: bool = True, timeout: int = 30):
        self._base = base_url.rstrip("/")
        self._device_id = device_id
        self._timeout = timeout
        self._session = requests.Session()
        self._session.verify = verify_tls
        self._session.headers.update({"x-api-key": api_key, "Accept": "application/json"})
        self._album_id: str | None = None

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

    def upload(self, path: str, sha1_hex_digest: str) -> UploadOutcome:
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
        with open(path, "rb") as fh:
            resp = self._session.post(
                self._base + "/api/assets",
                data=data,
                files={"assetData": (filename, fh, "application/octet-stream")},
                headers={"x-immich-checksum": sha1_hex_digest},
                # Big videos over a LAN: allow a long read timeout.
                timeout=(self._timeout, 3600),
            )
        if resp.status_code not in (200, 201):
            raise ImmichError(f"upload failed: HTTP {resp.status_code}: {resp.text[:300]}")
        body = resp.json()
        asset_id = body.get("id")
        duplicate = resp.status_code == 200 or body.get("status") == "duplicate"
        return UploadOutcome(status="duplicate" if duplicate else "imported", asset_id=asset_id)

    # -- albums ---------------------------------------------------------------

    def add_to_album(self, album_name: str, asset_id: str) -> None:
        """Adds an asset to the named album, creating the album on first use.
        Errors are logged, never raised — album placement is best-effort."""
        try:
            album_id = self._get_or_create_album(album_name)
            resp = self._session.put(
                f"{self._base}/api/albums/{album_id}/assets",
                json={"ids": [asset_id]},
                timeout=self._timeout,
            )
            resp.raise_for_status()
        except requests.RequestException as ex:
            log.warning("album add failed for %s: %s", asset_id, ex)

    def _get_or_create_album(self, album_name: str) -> str:
        if self._album_id:
            return self._album_id
        resp = self._session.get(self._base + "/api/albums", timeout=self._timeout)
        resp.raise_for_status()
        for album in resp.json():
            if album.get("albumName") == album_name:
                self._album_id = album["id"]
                return self._album_id
        resp = self._session.post(
            self._base + "/api/albums",
            json={"albumName": album_name},
            timeout=self._timeout,
        )
        resp.raise_for_status()
        self._album_id = resp.json()["id"]
        return self._album_id
