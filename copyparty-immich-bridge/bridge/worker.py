"""Import pipeline: dedupe-check, upload to Immich, record, post-import action."""

from __future__ import annotations

import itertools
import logging
import os
import queue
import threading

import requests

from bridge.config import Config
from bridge.immich import ImmichClient, ImmichError, UploadOutcome, sha1_hex
from bridge.scanner import extension_of, folder_album_name, is_candidate_name, is_within_dirs, iter_candidates
from bridge.state import StateStore

log = logging.getLogger("bridge.worker")


class ImportWorker:
    """Owns the work queue and the import pipeline.

    Paths are enqueued by the hook receiver and by the sweep; a pending-set
    keeps a path from being queued twice concurrently. Worker threads pull
    from the queue and run the full pipeline per file.
    """

    def __init__(self, cfg: Config, state: StateStore, client: ImmichClient, allowed_extensions: set[str]):
        self._cfg = cfg
        self._state = state
        self._client = client
        self._allowed = allowed_extensions
        # (priority, sequence, path): priority-dir files first, FIFO within a tier.
        self._queue: queue.PriorityQueue[tuple[int, int, str]] = queue.PriorityQueue()
        self._seq = itertools.count()
        self._pending: set[str] = set()
        self.album_permission: dict = {"ok": None, "missing": []}
        self.immich_user: dict | None = None
        self.backfill: dict = {"running": False, "total": 0, "done": 0, "failed": 0}
        self._backfill_lock = threading.Lock()
        self._lock = threading.Lock()
        self._held = 0  # files a worker has taken from the queue but is holding because imports are paused
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []

    # -- lifecycle -------------------------------------------------------------

    def start(self) -> None:
        for i in range(self._cfg.workers):
            t = threading.Thread(target=self._run, name=f"import-worker-{i}", daemon=True)
            t.start()
            self._threads.append(t)

    def stop(self) -> None:
        self._stop.set()
        for _ in self._threads:
            self._queue.put((-1, next(self._seq), ""))  # wake blocked workers

    @property
    def allowed_extensions(self) -> set[str]:
        return self._allowed

    @property
    def queue_size(self) -> int:
        """Files waiting to be imported (includes the ones held back while paused)."""
        with self._lock:
            return self._queue.qsize() + self._held

    # -- producers ---------------------------------------------------------------

    def enqueue(self, path: str, source: str) -> bool:
        """Queues a path unless it's already queued. Returns True if queued."""
        with self._lock:
            if path in self._pending:
                return False
            self._pending.add(path)
            seq = next(self._seq)
        priority = 0 if is_within_dirs(path, self._cfg.priority_dirs) else 1
        log.info("queued (%s%s): %s", source, ", priority" if priority == 0 else "", path)
        self._queue.put((priority, seq, path))
        return True

    def sweep(self) -> int:
        """Scans the watch dirs and queues everything not yet handled."""
        queued = 0
        excluded = {self._cfg.move_subdir}
        for path in iter_candidates(self._cfg.watch_dirs, self._allowed, self._cfg.min_file_age, excluded):
            try:
                stat = os.stat(path)
            except OSError:
                continue
            if self._state.is_done(path, stat.st_size, stat.st_mtime):
                continue
            if self._state.attempts_exhausted(path, stat.st_size, stat.st_mtime, self._cfg.max_attempts):
                continue
            if self.enqueue(path, "sweep"):
                queued += 1
        if queued:
            log.info("sweep queued %d file(s)", queued)
        return queued

    # -- pipeline ----------------------------------------------------------------

    def _wait_while_paused(self) -> bool:
        """Blocks while imports are paused. False when the bridge is stopping."""
        while self._cfg.paused and not self._stop.is_set():
            self._stop.wait(0.5)
        return not self._stop.is_set()

    def _run(self) -> None:
        while not self._stop.is_set():
            if not self._wait_while_paused():
                break
            _, _, path = self._queue.get()
            if not path or self._stop.is_set():
                break
            # Paused while this worker was waiting for work: hold the file (it stays marked as pending, so it
            # is not queued twice) until imports resume. A file already being imported always finishes.
            if self._cfg.paused:
                with self._lock:
                    self._held += 1
                try:
                    proceed = self._wait_while_paused()
                finally:
                    with self._lock:
                        self._held -= 1
                if not proceed:
                    break
            try:
                self._process(path)
            except Exception:
                log.exception("unexpected error processing %s", path)
            finally:
                with self._lock:
                    self._pending.discard(path)

    def _process(self, path: str) -> None:
        name = os.path.basename(path)
        if not is_candidate_name(name):
            return
        if not is_within_dirs(path, self._cfg.watch_dirs):
            # queued before a watched folder was removed in the settings page
            log.info("skipped, no longer in a watched folder: %s", path)
            return
        try:
            stat = os.stat(path)
        except OSError:
            log.info("gone before import: %s", path)
            return
        size, mtime = stat.st_size, stat.st_mtime

        # Hook-delivered paths haven't been extension-filtered yet.
        if extension_of(name) not in self._allowed:
            self._state.record_skip(path, size, mtime, "unsupported extension")
            log.debug("skipped (extension): %s", path)
            return
        if size == 0:
            return
        if self._state.is_done(path, size, mtime):
            return

        sha1: str | None = None
        try:
            sha1 = sha1_hex(path)

            existing = self._client.find_by_checksum(sha1, ref_id=path)
            if existing is not None:
                outcome = UploadOutcome(status="duplicate", asset_id=None if existing == "present" else existing)
                log.info("already in Immich (checksum): %s -> %s", name, existing)
            else:
                outcome = self._client.upload(path, sha1)
                log.info("%s: %s -> asset %s", outcome.status, name, outcome.asset_id)

            if outcome.asset_id and outcome.asset_id != "present":
                for album in self._albums_for(path):
                    if self._client.add_to_album(album, outcome.asset_id):
                        log.info("album %r <- %s", album, name)

            self._state.record_success(path, size, mtime, sha1, outcome.status, outcome.asset_id)
            self._post_import(path)
        except (ImmichError, requests.RequestException, OSError) as ex:
            log.warning("import failed for %s: %s", path, ex)
            self._state.record_failure(path, size, mtime, sha1, str(ex))

    # -- albums: permission check + back-fill of files imported before folder albums existed ----------------

    def check_album_permission(self) -> dict:
        """Asks Immich whether the API key may use albums, remembers the answer, and says so in the log."""
        self.album_permission = self._client.album_permission_status()
        if self._cfg.album_from_folder or self._cfg.album_name:
            if self.album_permission["ok"] is False:
                log.warning(
                    "the Immich API key cannot use albums (missing: %s) - files will import but NOT be added to "
                    "albums. Create a key with all permissions and re-run the installer with IMMICH_API_KEY=...",
                    ", ".join(self.album_permission["missing"]),
                )
            elif self.album_permission["ok"] is True:
                log.info("the Immich API key may create albums")
        return self.album_permission

    def refresh_identity(self) -> dict | None:
        """Which Immich account the API key belongs to (logged, and shown on the settings page)."""
        who = getattr(self._client, "whoami", lambda: None)()
        if who is not None:
            self.immich_user = who
            log.info("importing into the Immich account %s <%s> - log in as this user to see the photos and albums", who["name"], who["email"])
        return who

    def album_links(self, immich_url: str) -> list[dict]:
        known = getattr(self._client, "known_albums", dict)()
        return [{"name": n, "id": i, "url": f"{immich_url.rstrip('/')}/albums/{i}"} for n, i in sorted(known.items())]

    def album_info(self) -> dict:
        return {
            "enabled": bool(self._cfg.album_from_folder or self._cfg.album_name),
            "permission": self.album_permission,
            **getattr(self._client, "album_stats", {}),
            "backfill": dict(self.backfill),
        }

    def start_backfill(self) -> bool:
        """Adds everything already imported to its folder album, in the background. False if one is running."""
        with self._backfill_lock:
            if self.backfill["running"]:
                return False
            self.backfill = {"running": True, "total": 0, "done": 0, "failed": 0}
        threading.Thread(target=self._run_backfill, name="album-backfill", daemon=True).start()
        return True

    def _run_backfill(self) -> None:
        try:
            rows = self._state.done_assets()
            self.backfill["total"] = len(rows)
            log.info("adding %d already-imported file(s) to their folder albums", len(rows))
            for path, asset_id in rows:
                if self._stop.is_set():
                    break
                ok = True
                for album in self._albums_for(path):
                    ok = self._client.add_to_album(album, asset_id) and ok
                self.backfill["done"] += 1
                if not ok:
                    self.backfill["failed"] += 1
            log.info("album back-fill finished: %d done, %d failed", self.backfill["done"], self.backfill["failed"])
        except Exception:
            log.exception("album back-fill crashed")
        finally:
            self.backfill["running"] = False

    def _albums_for(self, path: str) -> list[str]:
        """Albums this file goes into: the fixed album (if set) and the folder-named one (if enabled)."""
        albums: list[str] = []
        if self._cfg.album_name:
            albums.append(self._cfg.album_name)
        if self._cfg.album_from_folder:
            folder = folder_album_name(path)
            if folder and folder not in albums:
                albums.append(folder)
        return albums

    def _post_import(self, path: str) -> None:
        """Applies the configured post-import action. Only reached after the
        import was recorded as imported/duplicate, so the bytes are safe in
        Immich (or were already there) before anything is touched."""
        action = self._cfg.post_import_action
        if action == "keep":
            return
        try:
            if action == "delete":
                os.remove(path)
                log.info("deleted after import: %s", path)
            elif action == "move":
                target_dir = os.path.join(os.path.dirname(path), self._cfg.move_subdir)
                os.makedirs(target_dir, exist_ok=True)
                target = os.path.join(target_dir, os.path.basename(path))
                os.replace(path, target)
                log.info("moved after import: %s -> %s", path, target)
        except OSError as ex:
            # Read-only mount or permissions — the import itself succeeded, so
            # just log it (the state DB stops any re-import).
            log.warning("post-import %s failed for %s: %s", action, path, ex)
