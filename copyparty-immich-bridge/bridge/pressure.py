"""Back off while Immich or the machine it runs on is overloaded.

Signals: the machine's load per CPU (inside a container os.getloadavg() is the host VM's), how fast Immich answers a
ping, and server errors / timeouts seen on real work. While busy no new upload or Immich write starts (one already
running finishes). Checks then wait 1, 2, 4 ... up to 30 minutes, and work resumes after one healthy check.
"""

from __future__ import annotations

import logging
import os
import threading
import time
from collections.abc import Callable

log = logging.getLogger(__name__)


def _f(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return default


LOAD_HIGH = _f("BACKOFF_LOAD", 3.0)  # load per CPU that counts as overloaded
LOAD_OK = _f("BACKOFF_LOAD_OK", 1.5)  # and the level it must be under to resume
PING_SLOW_S = _f("BACKOFF_PING_S", 5.0)
FIRST_WAIT_S, MAX_WAIT_S, CHECK_S = 60, 1800, 30


def machine_load() -> float | None:
    try:
        return os.getloadavg()[0] / max(1, os.cpu_count() or 1)
    except OSError:
        return None


def overload_error(ex: BaseException) -> bool:
    """A failure that means 'Immich is struggling' rather than 'this file is bad'."""
    text = f"{type(ex).__name__} {ex}".lower()
    return any(s in text for s in ("timeout", "timed out", "connectionerror", "connection aborted", "connection refused",
                                   "http 429", "http 500", "http 502", "http 503", "http 504", "remote end closed"))


class Pressure:
    def __init__(self, ping: Callable[[], float | None] | None = None, load: Callable[[], float | None] = machine_load,
                 clock: Callable[[], float] = time.time):
        self._ping, self._load, self._clock = ping, load, clock
        self._lock = threading.Lock()
        self.busy = False
        self.reason = ""
        self.since = 0.0
        self.until = 0.0
        self.level = 0
        self.listeners: list[Callable[[dict], None]] = []
        self._stop = threading.Event()

    def describe(self) -> dict:
        with self._lock:
            return {"busy": self.busy, "reason": self.reason, "since": self.since or None, "until": self.until or None,
                    "level": self.level}

    def _notify(self) -> None:
        info = self.describe()
        for fn in list(self.listeners):
            try:
                fn(info)
            except Exception:
                log.exception("backoff listener failed")

    def measure(self) -> str:
        """Why Immich should be left alone right now ('' = healthy)."""
        load = self._load()
        limit = LOAD_OK if self.busy else LOAD_HIGH
        if load is not None and load >= limit:
            return f"the server is overloaded (load {load:.1f} per CPU)"
        if self._ping is not None:
            took = self._ping()
            if took is None:
                return "Immich does not answer"
            if took >= PING_SLOW_S:
                return f"Immich is slow to answer ({took:.0f} s)"
        return ""

    def _enter(self, reason: str) -> None:
        now = self._clock()
        with self._lock:
            first = not self.busy
            self.level = 0 if first else min(self.level + 1, 10)
            self.busy, self.reason = True, reason
            self.since = now if first else self.since
            self.until = now + min(MAX_WAIT_S, FIRST_WAIT_S * 2 ** self.level)
        if first:
            log.warning("backing off: %s - no new imports or Immich changes until %s", reason, time.strftime("%H:%M", time.localtime(self.until)))
        self._notify()

    def report_error(self, ex: BaseException) -> None:
        """Real work failed in a way that means Immich is struggling: back off now."""
        if overload_error(ex):
            self._enter(f"Immich failed a request ({str(ex)[:80]})")

    def check(self) -> None:
        """One step of the monitor: start backing off, keep waiting, or resume."""
        now = self._clock()
        if self.busy and now < self.until:
            return
        reason = self.measure()
        if reason:
            self._enter(reason)
        elif self.busy:
            with self._lock:
                took = int(now - self.since)
                self.busy, self.reason, self.since, self.until, self.level = False, "", 0.0, 0.0, 0
            log.info("Immich is healthy again after %d min: resuming", took // 60)
            self._notify()

    def wait_until_clear(self, stop: threading.Event) -> bool:
        """Blocks while busy. False when stopping."""
        while self.busy and not stop.is_set():
            stop.wait(1)
        return not stop.is_set()

    def run(self) -> None:
        while not self._stop.wait(CHECK_S):
            try:
                self.check()
            except Exception:
                log.exception("backoff check failed")

    def start(self) -> None:
        threading.Thread(target=self.run, name="backoff", daemon=True).start()

    def stop(self) -> None:
        self._stop.set()


# One per bridge: every person's worker and the auto-fix share the same Immich and the same machine.
PRESSURE = Pressure()
