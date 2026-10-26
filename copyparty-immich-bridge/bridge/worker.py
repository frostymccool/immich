"""Import pipeline: dedupe-check, upload to Immich, record, post-import action."""

from __future__ import annotations

import collections
import itertools
import logging
import os
import queue
import threading
import time

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
        # Set when the API key now belongs to a different Immich account than the one files were imported into.
        self.account_change: dict | None = None
        self.backfill: dict = {"running": False, "total": 0, "done": 0, "failed": 0}
        self._backfill_lock = threading.Lock()
        self._lock = threading.Lock()
        # path -> progress of a file being imported now: started, phase, bytes sent/total, when the upload began
        self._active: dict[str, dict] = {}
        self._sizes: dict[str, int] = {}  # size of each queued/active file, for the backlog estimate
        self._sent_total = 0  # bytes uploaded since start
        self._samples: collections.deque[tuple[float, int]] = collections.deque(maxlen=400)  # (time, _sent_total)
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

    def active(self) -> list[dict]:
        """Files being imported right now: name, phase, seconds so far, upload percent/bytes and an ETA."""
        now = time.time()
        with self._lock:
            out = []
            for p, a in self._active.items():
                item = {
                    "name": os.path.basename(p),
                    "phase": a["phase"],
                    "seconds": int(now - a["t0"]),
                    "percent": int(a["sent"] * 100 / a["total"]) if a["total"] else None,
                    "sent": a["sent"],
                    "total": a["total"],
                    "eta_seconds": None,
                    "rate": None,
                }
                up = now - a["up0"] if a["up0"] else 0
                if a["phase"] == "uploading" and up >= 3 and a["sent"] > 0:
                    item["rate"] = int(a["sent"] / up)
                    item["eta_seconds"] = int((a["total"] - a["sent"]) / (a["sent"] / up))
                out.append(item)
            return out

    def _recent_rate(self, now: float) -> float | None:
        """Bytes/second actually uploaded over the last two minutes (all workers together, hashing included)."""
        recent = [x for x in self._samples if now - x[0] <= 120]
        if len(recent) < 2 or now - recent[-1][0] > 30:
            return None
        dt = recent[-1][0] - recent[0][0]
        if dt < 3:
            return None
        return (recent[-1][1] - recent[0][1]) / dt

    def backlog(self) -> dict:
        """Everything still to import (queued + running): file count, bytes left and an ETA for all of it.
        An estimate: files Immich already has are skipped without uploading, so it is an upper bound."""
        now = time.time()
        with self._lock:
            files = len(self._pending)
            left = 0
            for p in self._pending:
                a = self._active.get(p)
                if a and a["total"]:
                    left += a["total"] - a["sent"]
                else:
                    left += self._sizes.get(p, 0)
            rate = self._recent_rate(now)
        return {
            "files": files,
            "bytes_left": left,
            "rate": int(rate) if rate else None,
            "eta_seconds": int(left / rate) if rate and left else None,
        }

    def _phase(self, path: str, phase: str, sent: int = 0, total: int = 0) -> None:
        now = time.time()
        with self._lock:
            a = self._active.setdefault(path, {"t0": now, "phase": "", "sent": 0, "total": 0, "up0": None})
            a["phase"] = phase
            if phase == "uploading":
                if a["up0"] is None:
                    a["up0"] = now
                self._sent_total += max(0, sent - a["sent"])
                a["sent"], a["total"] = sent, total
                if not self._samples or now - self._samples[-1][0] >= 0.5 or sent == total:
                    self._samples.append((now, self._sent_total))

    # -- producers ---------------------------------------------------------------

    def enqueue(self, path: str, source: str) -> bool:
        """Queues a path unless it's already queued. Returns True if queued."""
        with self._lock:
            if path in self._pending:
                return False
            self._pending.add(path)
            try:
                self._sizes[path] = os.stat(path).st_size
            except OSError:
                pass
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
                    self._sizes.pop(path, None)

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
        self._phase(path, "hashing")
        try:
            sha1 = sha1_hex(path)
            self._phase(path, "checking Immich")

            existing = self._client.find_by_checksum(sha1, ref_id=path)
            if existing is not None:
                outcome = UploadOutcome(status="duplicate", asset_id=None if existing == "present" else existing)
                log.info("already in Immich (checksum): %s -> %s", name, existing)
            else:
                self._phase(path, "uploading", 0, 0)
                outcome = self._client.upload(
                    path, sha1, progress=lambda sent, total: self._phase(path, "uploading", sent, total)
                )
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
        finally:
            with self._lock:
                self._active.pop(path, None)
                self._sizes.pop(path, None)

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
            self._track_account(who)
            log.info("importing into the Immich account %s <%s> - log in as this user to see the photos and albums", who["name"], who["email"])
        return who

    def _track_account(self, who: dict) -> None:
        """Remembers which Immich account files are imported into; flags it when the key moves to another one."""
        if not who.get("id"):
            return
        stored = self._state.get_meta("immich_user_id")
        if stored is None:
            self._remember_account(who)
            self.account_change = None
        elif stored != who["id"]:
            was = f"{self._state.get_meta('immich_user_name') or '?'} <{self._state.get_meta('immich_user_email') or '?'}>"
            now = f"{who['name']} <{who['email']}>"
            self.account_change = {"was": was, "now": now}
            log.warning(
                "the API key now belongs to a DIFFERENT Immich account (was %s, now %s). Files imported before are in "
                "the old account; use 'Re-import everything' on the settings page to import them into the new one.",
                was,
                now,
            )
        else:
            self.account_change = None

    def _remember_account(self, who: dict) -> None:
        self._state.set_meta("immich_user_id", who["id"])
        self._state.set_meta("immich_user_name", who.get("name", ""))
        self._state.set_meta("immich_user_email", who.get("email", ""))

    def acknowledge_account(self) -> None:
        """The user says the current account is the right one: stop warning about the change."""
        if self.immich_user and self.immich_user.get("id"):
            self._remember_account(self.immich_user)
        self.account_change = None

    def reimport_everything(self) -> int:
        """Forgets that anything was imported (files and Immich are untouched) so the next scan imports it all
        again, into whichever account the key belongs to now. Returns how many records were forgotten."""
        forgotten = self._state.forget_all()
        self.acknowledge_account()
        log.warning("forgot %d imported-file record(s): everything will be imported again", forgotten)
        return forgotten

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
