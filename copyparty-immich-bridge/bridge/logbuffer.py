"""In-memory ring buffer of recent log lines, for the web page's log viewer."""

from __future__ import annotations

import itertools
import logging
import threading
import time
from collections import deque

LEVELS = {"DEBUG": 10, "INFO": 20, "WARNING": 30, "ERROR": 40, "CRITICAL": 50}


class RingLogHandler(logging.Handler):
    def __init__(self, capacity: int = 2000):
        super().__init__(level=logging.DEBUG)
        self._lock_buf = threading.Lock()
        self._buf: deque[dict] = deque(maxlen=capacity)
        self._ids = itertools.count(1)

    def emit(self, record: logging.LogRecord) -> None:
        try:
            msg = record.getMessage()
            if record.exc_info:
                msg += "\n" + (self.formatter or logging.Formatter()).formatException(record.exc_info)
        except Exception:
            return
        entry = {
            "id": 0,
            "ts": record.created,
            "level": record.levelname,
            "logger": record.name,
            "message": msg,
        }
        with self._lock_buf:
            entry["id"] = next(self._ids)
            self._buf.append(entry)

    def entries(self, min_level: str = "INFO", limit: int = 300, after: int = 0) -> list[dict]:
        floor = LEVELS.get(min_level.upper(), 20)
        with self._lock_buf:
            rows = [e for e in self._buf if e["id"] > after and LEVELS.get(e["level"], 20) >= floor]
        return rows[-limit:] if limit > 0 else rows

    @staticmethod
    def format_line(e: dict) -> str:
        ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(e["ts"]))
        return f"{ts} {e['level']:<7} {e['logger']}: {e['message']}"

    def text(self, min_level: str = "DEBUG") -> str:
        return "\n".join(self.format_line(e) for e in self.entries(min_level, limit=0)) + "\n"
