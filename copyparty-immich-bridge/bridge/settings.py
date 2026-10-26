"""Runtime-editable settings, layered on top of the environment configuration.

The environment (compose file) supplies the defaults. Anything saved through
the web page is stored in a small JSON file on the state volume and wins over
the environment until it is reset. Changes are validated, applied to the live
`Config` object (so the worker, sweep and hook receiver pick them up without a
restart) and persisted atomically.
"""

from __future__ import annotations

import json
import logging
import os
import threading
from collections.abc import Callable
from typing import Any

from bridge.config import VALID_POST_IMPORT_ACTIONS, Config, normalize_ext
from bridge.scanner import is_within_dirs

log = logging.getLogger("bridge.settings")

VALID_LOG_LEVELS = ("DEBUG", "INFO", "WARNING", "ERROR")

# Settings the web page may change. Everything else (Immich URL, API key, port,
# worker count, ...) needs a container restart or a compose change and is shown
# read-only instead.
EDITABLE = (
    "watch_dirs",
    "priority_dirs",
    "sweep_interval",
    "min_file_age",
    "max_attempts",
    "post_import_action",
    "album_name",
    "include_extensions",
    "log_level",
)


class SettingsError(Exception):
    """Raised with a list of human-readable problems; nothing is applied."""

    def __init__(self, problems: list[str]):
        super().__init__("; ".join(problems))
        self.problems = problems


def _norm_dir(raw: Any) -> str | None:
    if not isinstance(raw, str):
        return None
    raw = raw.strip()
    if not raw.startswith("/"):
        return None
    return os.path.normpath(raw) or "/"


def _clean_dirs(value: Any, name: str, problems: list[str]) -> list[str]:
    if isinstance(value, str):
        value = [v for v in value.replace(",", "\n").splitlines()]
    if not isinstance(value, list):
        problems.append(f"{name} must be a list of folder paths")
        return []
    out: list[str] = []
    for item in value:
        if isinstance(item, str) and not item.strip():
            continue
        norm = _norm_dir(item)
        if norm is None:
            problems.append(f"{name}: {item!r} is not an absolute path")
        elif norm not in out:
            out.append(norm)
    return out


def _int_in(value: Any, name: str, low: int, high: int, problems: list[str]) -> int | None:
    if isinstance(value, bool):
        problems.append(f"{name} must be a whole number")
        return None
    try:
        num = int(value)
    except (TypeError, ValueError):
        problems.append(f"{name} must be a whole number")
        return None
    if not low <= num <= high:
        problems.append(f"{name} must be between {low} and {high}")
        return None
    return num


def validate(cfg: Config, changes: dict[str, Any], browse_roots: list[str]) -> dict[str, Any]:
    """Returns the normalised subset of `changes` to apply, or raises SettingsError."""
    problems: list[str] = []
    out: dict[str, Any] = {}

    unknown = sorted(set(changes) - set(EDITABLE))
    if unknown:
        problems.append(f"not editable here: {', '.join(unknown)}")

    if "watch_dirs" in changes:
        dirs = _clean_dirs(changes["watch_dirs"], "watch_dirs", problems)
        if not dirs and not problems:
            problems.append("watch_dirs needs at least one folder")
        for d in dirs:
            if browse_roots and not is_within_dirs(d, browse_roots):
                problems.append(f"{d} is outside the folders this container can see ({', '.join(browse_roots)})")
            elif not os.path.isdir(d):
                problems.append(f"{d} does not exist in the container (is it mounted?)")
        out["watch_dirs"] = dirs

    if "priority_dirs" in changes:
        out["priority_dirs"] = _clean_dirs(changes["priority_dirs"], "priority_dirs", problems)

    if "sweep_interval" in changes:
        v = _int_in(changes["sweep_interval"], "sweep_interval", 0, 7 * 86400, problems)
        if v is not None:
            out["sweep_interval"] = v
    if "min_file_age" in changes:
        v = _int_in(changes["min_file_age"], "min_file_age", 0, 3600, problems)
        if v is not None:
            out["min_file_age"] = v
    if "max_attempts" in changes:
        v = _int_in(changes["max_attempts"], "max_attempts", 1, 100, problems)
        if v is not None:
            out["max_attempts"] = v

    if "post_import_action" in changes:
        action = str(changes["post_import_action"]).strip().lower()
        if action not in VALID_POST_IMPORT_ACTIONS:
            problems.append(f"post_import_action must be one of {', '.join(VALID_POST_IMPORT_ACTIONS)}")
        else:
            out["post_import_action"] = action

    if "album_name" in changes:
        album = str(changes["album_name"] or "").strip()
        if len(album) > 200:
            problems.append("album_name is too long")
        else:
            out["album_name"] = album

    if "include_extensions" in changes:
        raw = changes["include_extensions"]
        if isinstance(raw, str):
            raw = raw.replace(",", " ").split()
        if not isinstance(raw, list):
            problems.append("include_extensions must be a list of extensions")
        else:
            exts = {normalize_ext(str(x)) for x in raw}
            exts.discard("")
            out["include_extensions"] = exts

    if "log_level" in changes:
        level = str(changes["log_level"]).strip().upper()
        if level not in VALID_LOG_LEVELS:
            problems.append(f"log_level must be one of {', '.join(VALID_LOG_LEVELS)}")
        else:
            out["log_level"] = level

    # Cross-field rules use the merged result, so changing only one side still works.
    watch = out.get("watch_dirs", cfg.watch_dirs)
    prio = out.get("priority_dirs", cfg.priority_dirs)
    if not problems and ("watch_dirs" in out or "priority_dirs" in out):
        for d in prio:
            if not is_within_dirs(d, watch):
                problems.append(f"priority folder {d} must be inside one of the watched folders")
    action = out.get("post_import_action", cfg.post_import_action)
    if not problems and action != "keep" and ("post_import_action" in out or "watch_dirs" in out):
        for d in watch:
            if os.path.isdir(d) and not os.access(d, os.W_OK):
                problems.append(f"post_import_action '{action}' needs write access, but {d} is mounted read-only")

    if problems:
        raise SettingsError(problems)
    return out


def _jsonable(key: str, value: Any) -> Any:
    if key == "include_extensions":
        return sorted(value)
    if isinstance(value, list):
        return list(value)
    return value


class SettingsStore:
    def __init__(
        self,
        cfg: Config,
        path: str,
        browse_roots: list[str] | None = None,
        on_change: Callable[[], None] | None = None,
    ):
        self._cfg = cfg
        self._path = path
        self._lock = threading.Lock()
        self.browse_roots = browse_roots or []
        self._on_change = on_change
        self._defaults = {k: _jsonable(k, getattr(cfg, k)) for k in EDITABLE}
        self._overrides: dict[str, Any] = {}

    # -- reading -----------------------------------------------------------------

    def values(self) -> dict[str, Any]:
        return {k: _jsonable(k, getattr(self._cfg, k)) for k in EDITABLE}

    def defaults(self) -> dict[str, Any]:
        return dict(self._defaults)

    def overridden(self) -> list[str]:
        with self._lock:
            return sorted(self._overrides)

    # -- startup -----------------------------------------------------------------

    def load(self) -> None:
        """Applies the saved overrides, if any. A bad file never stops startup."""
        try:
            with open(self._path, encoding="utf-8") as fh:
                data = json.load(fh)
        except FileNotFoundError:
            return
        except (OSError, ValueError) as ex:
            log.warning("ignoring unreadable settings file %s: %s", self._path, ex)
            return
        overrides = data.get("overrides") if isinstance(data, dict) else None
        if not isinstance(overrides, dict):
            log.warning("ignoring settings file %s: unexpected shape", self._path)
            return
        usable: dict[str, Any] = {}
        with self._lock:
            # watch_dirs first so priority_dirs is checked against the folders it will live in
            for key in sorted(overrides, key=lambda k: (k != "watch_dirs", k)):
                try:
                    clean = validate(self._cfg, {key: overrides[key]}, self.browse_roots)
                except SettingsError as ex:
                    # e.g. a folder that is not mounted right now: keep the env default for it
                    log.warning("saved setting %s ignored: %s", key, ex)
                    continue
                self._apply(clean)
                usable.update(clean)
            self._overrides = {k: _jsonable(k, v) for k, v in usable.items()}
        if usable:
            log.info("loaded saved settings: %s", ", ".join(sorted(usable)))

    # -- writing -----------------------------------------------------------------

    def update(self, changes: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            clean = validate(self._cfg, changes, self.browse_roots)
            actually = [k for k, v in clean.items() if _jsonable(k, getattr(self._cfg, k)) != _jsonable(k, v)]
            self._apply(clean)
            for key, value in clean.items():
                if _jsonable(key, value) == self._defaults[key]:
                    self._overrides.pop(key, None)
                else:
                    self._overrides[key] = _jsonable(key, value)
            self._persist()
        log.info("settings changed: %s", ", ".join(sorted(actually)) or "nothing")
        self._notify()
        return self.values()

    def reset(self) -> dict[str, Any]:
        with self._lock:
            restored = {
                k: (set(v) if k == "include_extensions" else list(v) if isinstance(v, list) else v)
                for k, v in self._defaults.items()
            }
            self._apply(restored)
            self._overrides = {}
            self._persist()
        log.info("settings reset to the installer/environment defaults")
        self._notify()
        return self.values()

    # -- internals ---------------------------------------------------------------

    def _apply(self, clean: dict[str, Any]) -> None:
        for key, value in clean.items():
            setattr(self._cfg, key, value)
        if "log_level" in clean:
            logging.getLogger().setLevel(getattr(logging, clean["log_level"], logging.INFO))

    def _persist(self) -> None:
        directory = os.path.dirname(self._path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        tmp = self._path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "overrides": self._overrides}, fh, indent=2, sort_keys=True)
        os.replace(tmp, self._path)

    def _notify(self) -> None:
        if self._on_change is not None:
            try:
                self._on_change()
            except Exception:
                log.exception("settings change callback failed")
