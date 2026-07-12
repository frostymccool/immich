"""Import pipeline: dedupe-check, upload to Immich, record, post-import action."""

from __future__ import annotations

import logging
import os
import queue
import threading

import requests

from bridge.config import Config
from bridge.immich import ImmichClient, ImmichError, UploadOutcome, sha1_hex
from bridge.scanner import extension_of, is_candidate_name, iter_candidates
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
        self._queue: queue.Queue[str] = queue.Queue()
        self._pending: set[str] = set()
        self._lock = threading.Lock()
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
            self._queue.put("")  # wake blocked workers

    @property
    def queue_size(self) -> int:
        return self._queue.qsize()

    # -- producers ---------------------------------------------------------------

    def enqueue(self, path: str, source: str) -> bool:
        """Queues a path unless it's already queued. Returns True if queued."""
        with self._lock:
            if path in self._pending:
                return False
            self._pending.add(path)
        log.info("queued (%s): %s", source, path)
        self._queue.put(path)
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

    def _run(self) -> None:
        while not self._stop.is_set():
            path = self._queue.get()
            if not path or self._stop.is_set():
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

            if self._cfg.album_name and outcome.asset_id and outcome.asset_id != "present":
                self._client.add_to_album(self._cfg.album_name, outcome.asset_id)

            self._state.record_success(path, size, mtime, sha1, outcome.status, outcome.asset_id)
            self._post_import(path)
        except (ImmichError, requests.RequestException, OSError) as ex:
            log.warning("import failed for %s: %s", path, ex)
            self._state.record_failure(path, size, mtime, sha1, str(ex))

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
