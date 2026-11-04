"""A person's view of the configuration: the global Config with a few fields replaced by that person's own.

Everything not listed here (sweep interval, file-age guard, retries, post-import action, Immich URL, workers ...)
is read live from the global Config, so a settings change still applies to everybody at once.
"""

from __future__ import annotations

from bridge.config import Config
from bridge.users import MAIN_ID, User, UsersStore


class UserView:
    """For the main account only `paused` differs (its own pause switch next to the global one)."""

    def __init__(self, cfg: Config, uid: str, store: UsersStore):
        self._cfg = cfg
        self._store = store
        self.uid = uid
        # Set by the manager: the reason this person's imports are held (same Immich account as someone else ...).
        self.blocked: str | None = None

    def _user(self) -> User | None:
        return None if self.uid == MAIN_ID else self._store.get(self.uid)

    def __getattr__(self, name: str):
        return getattr(self._cfg, name)

    @property
    def paused(self) -> bool:
        if self._cfg.paused or self.blocked:
            return True
        user = self._user()
        return bool(self._store.main.get("paused")) if self.uid == MAIN_ID else bool(user and user.paused)

    @property
    def api_key(self) -> str:
        user = self._user()
        return user.api_key if user else self._cfg.api_key

    @property
    def watch_dirs(self) -> list[str]:
        user = self._user()
        return user.folders if user else self._cfg.watch_dirs

    @property
    def priority_dirs(self) -> list[str]:
        user = self._user()
        return user.priority_dirs if user else self._cfg.priority_dirs

    @property
    def album_name(self) -> str:
        user = self._user()
        return user.album_name if user else self._cfg.album_name

    @property
    def album_from_folder(self) -> bool:
        user = self._user()
        return user.album_from_folder if user else self._cfg.album_from_folder
