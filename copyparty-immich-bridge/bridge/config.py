"""Environment-variable configuration for the bridge."""

from __future__ import annotations

import os
from dataclasses import dataclass, field

VALID_POST_IMPORT_ACTIONS = ("keep", "move", "delete")


class ConfigError(Exception):
    pass


def _split_list(raw: str) -> list[str]:
    """Splits on commas or colons, drops empties and whitespace."""
    parts: list[str] = []
    for chunk in raw.replace(":", ",").split(","):
        chunk = chunk.strip()
        if chunk:
            parts.append(chunk)
    return parts


def _normalize_ext(ext: str) -> str:
    return ext.strip().lstrip(".").lower()


@dataclass
class Config:
    immich_url: str
    api_key: str
    watch_dirs: list[str]

    # Maps a path prefix as seen by copyparty (the hook's "ap") to the prefix
    # where the same volume is mounted in THIS container. Empty = identical.
    path_map: list[tuple[str, str]] = field(default_factory=list)

    sweep_interval: int = 900
    min_file_age: int = 30
    max_attempts: int = 5

    post_import_action: str = "keep"
    move_subdir: str = ".imported"

    album_name: str = ""

    # Explicit extension allow-list; empty = ask Immich /server/media-types.
    include_extensions: set[str] = field(default_factory=set)

    bind_host: str = "0.0.0.0"
    bind_port: int = 8099

    state_db: str = "/data/state.db"
    device_id: str = "copyparty-immich-bridge"
    verify_tls: bool = True
    workers: int = 1
    log_level: str = "INFO"

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> "Config":
        e = os.environ if env is None else env

        immich_url = e.get("IMMICH_URL", "").strip().rstrip("/")
        if not immich_url:
            raise ConfigError("IMMICH_URL is required (e.g. http://immich-server:2283)")

        api_key = e.get("IMMICH_API_KEY", "").strip()
        key_file = e.get("IMMICH_API_KEY_FILE", "").strip()
        if not api_key and key_file:
            try:
                with open(key_file, encoding="utf-8") as fh:
                    api_key = fh.read().strip()
            except OSError as ex:
                raise ConfigError(f"cannot read IMMICH_API_KEY_FILE {key_file}: {ex}") from ex
        if not api_key:
            raise ConfigError("IMMICH_API_KEY (or IMMICH_API_KEY_FILE) is required")

        watch_dirs = [d.rstrip("/") or "/" for d in _split_list(e.get("WATCH_DIRS", ""))]
        if not watch_dirs:
            raise ConfigError("WATCH_DIRS is required (comma-separated container paths)")

        path_map: list[tuple[str, str]] = []
        raw_map = e.get("PATH_MAP", "").strip()
        if raw_map:
            for pair in raw_map.split(","):
                pair = pair.strip()
                if not pair:
                    continue
                if "=" not in pair:
                    raise ConfigError(f"PATH_MAP entry {pair!r} must look like /copyparty/prefix=/bridge/prefix")
                src, dst = pair.split("=", 1)
                src, dst = src.strip().rstrip("/"), dst.strip().rstrip("/")
                if not src or not dst:
                    raise ConfigError(f"PATH_MAP entry {pair!r} has an empty side")
                path_map.append((src, dst))

        action = e.get("POST_IMPORT_ACTION", "keep").strip().lower()
        if action not in VALID_POST_IMPORT_ACTIONS:
            raise ConfigError(f"POST_IMPORT_ACTION must be one of {VALID_POST_IMPORT_ACTIONS}, got {action!r}")

        include_extensions = {_normalize_ext(x) for x in _split_list(e.get("INCLUDE_EXTENSIONS", ""))}
        include_extensions.discard("")

        def _int(name: str, default: int, minimum: int = 0) -> int:
            raw = e.get(name, "").strip()
            if not raw:
                return default
            try:
                val = int(raw)
            except ValueError as ex:
                raise ConfigError(f"{name} must be an integer, got {raw!r}") from ex
            if val < minimum:
                raise ConfigError(f"{name} must be >= {minimum}, got {val}")
            return val

        return cls(
            immich_url=immich_url,
            api_key=api_key,
            watch_dirs=watch_dirs,
            path_map=path_map,
            sweep_interval=_int("SWEEP_INTERVAL_SECONDS", 900),
            min_file_age=_int("MIN_FILE_AGE_SECONDS", 30),
            max_attempts=_int("MAX_ATTEMPTS", 5, minimum=1),
            post_import_action=action,
            move_subdir=e.get("MOVE_SUBDIR", ".imported").strip() or ".imported",
            album_name=e.get("IMMICH_ALBUM_NAME", "").strip(),
            include_extensions=include_extensions,
            bind_host=e.get("BIND_HOST", "0.0.0.0").strip() or "0.0.0.0",
            bind_port=_int("BIND_PORT", 8099, minimum=1),
            state_db=e.get("STATE_DB", "/data/state.db").strip() or "/data/state.db",
            device_id=e.get("DEVICE_ID", "copyparty-immich-bridge").strip() or "copyparty-immich-bridge",
            verify_tls=e.get("IMMICH_VERIFY_TLS", "true").strip().lower() not in ("0", "false", "no"),
            workers=_int("WORKERS", 1, minimum=1),
            log_level=e.get("LOG_LEVEL", "INFO").strip().upper() or "INFO",
        )

    def map_hook_path(self, ap: str) -> str:
        """Translates a copyparty-container absolute path to a local path."""
        for src, dst in self.path_map:
            if ap == src or ap.startswith(src + "/"):
                return dst + ap[len(src):]
        return ap
