"""Read-only folder listing for the web page's folder picker.

Only ever lists directories, and only inside the configured browse roots
(the folders mounted into this container). Symlinks are resolved first so a
link cannot be used to step outside the roots.
"""

from __future__ import annotations

import os

from bridge.scanner import is_within_dirs

MAX_ENTRIES = 500
COUNT_CAP = 2000


class BrowseError(Exception):
    def __init__(self, message: str, code: int = 400):
        super().__init__(message)
        self.code = code


def list_dir(path: str | None, roots: list[str], media_exts: set[str] | None = None) -> dict:
    if not roots:
        raise BrowseError("folder browsing is not enabled (BROWSE_ROOTS is empty)", 404)

    real_roots = [os.path.realpath(r) for r in roots]
    target = os.path.normpath(path) if path else roots[0]
    if not os.path.isabs(target):
        raise BrowseError("path must be absolute")
    real = os.path.realpath(target)
    if not is_within_dirs(real, real_roots):
        raise BrowseError("that folder is outside the folders this container can see", 403)
    if not os.path.isdir(real):
        raise BrowseError("not a folder", 404)

    dirs: list[dict] = []
    files = 0
    truncated = False
    try:
        with os.scandir(real) as it:
            for n, entry in enumerate(sorted(it, key=lambda e: e.name.lower())):
                if n >= COUNT_CAP:
                    truncated = True
                    break
                if entry.name.startswith("."):
                    continue
                try:
                    if entry.is_dir(follow_symlinks=True):
                        full = os.path.realpath(entry.path)
                        if not is_within_dirs(full, real_roots):
                            continue
                        if len(dirs) < MAX_ENTRIES:
                            dirs.append({"name": entry.name, "path": os.path.join(target, entry.name)})
                        else:
                            truncated = True
                    elif entry.is_file(follow_symlinks=False):
                        name = entry.name.lower()
                        if media_exts is None or name.rsplit(".", 1)[-1] in media_exts:
                            files += 1
                except OSError:
                    continue
    except PermissionError as ex:
        raise BrowseError(f"cannot read that folder: {ex.strerror}", 403) from ex

    parent = None
    norm_roots = [os.path.normpath(r) for r in roots]
    if target not in norm_roots and os.path.dirname(target) != target:
        parent = os.path.dirname(target)
    return {"path": target, "parent": parent, "roots": norm_roots, "dirs": dirs, "files": files, "truncated": truncated}
