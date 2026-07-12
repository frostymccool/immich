"""Filesystem sweep: finds import candidates under the watch directories.

The sweep is the reconciliation path — it guarantees nothing is missed while
the bridge (or the hook) was down. Event hooks make imports instant; the
sweep makes them reliable.
"""

from __future__ import annotations

import logging
import os
import time
from collections.abc import Iterator

log = logging.getLogger("bridge.scanner")

# copyparty keeps its upload database/snapshots in .hist at the volume root;
# in-progress up2k uploads are `<name>.PARTIAL` / `.<name>.PARTIAL`.
_PARTIAL_SUFFIX = ".partial"


def is_candidate_name(name: str) -> bool:
    """Cheap name-based filter: no dotfiles, no copyparty partials."""
    if name.startswith("."):
        return False
    return not name.lower().endswith(_PARTIAL_SUFFIX)


def extension_of(name: str) -> str:
    dot = name.rfind(".")
    if dot <= 0 or dot == len(name) - 1:
        return ""
    return name[dot + 1 :].lower()


def iter_candidates(
    watch_dirs: list[str],
    allowed_extensions: set[str],
    min_file_age: int,
    excluded_dir_names: set[str] | None = None,
    now: float | None = None,
) -> Iterator[str]:
    """Yields absolute paths of complete, compatible, settled files.

    - skips hidden dirs (covers copyparty's .hist) and `excluded_dir_names`
      (the post-import move target)
    - skips dotfiles, .PARTIAL files, empty files, unsupported extensions
    - skips files modified less than `min_file_age` seconds ago, so a file
      still being written by a non-up2k client isn't grabbed mid-write
    """
    now = time.time() if now is None else now
    excluded = excluded_dir_names or set()

    for root_dir in watch_dirs:
        if not os.path.isdir(root_dir):
            log.warning("watch dir missing or not mounted: %s", root_dir)
            continue
        for parent, dirs, files in os.walk(root_dir):
            dirs[:] = [d for d in dirs if not d.startswith(".") and d not in excluded]
            for name in files:
                if not is_candidate_name(name):
                    continue
                if extension_of(name) not in allowed_extensions:
                    continue
                path = os.path.join(parent, name)
                try:
                    stat = os.stat(path)
                except OSError:
                    continue  # vanished between listing and stat
                if stat.st_size == 0:
                    continue
                if now - stat.st_mtime < min_file_age:
                    continue
                yield path
