#!/usr/bin/env python3
"""Stand-in for exiftool in tests: answers `-ver` and `-json ... -- files` from a manifest.

The manifest (FAKE_EXIFTOOL_MANIFEST, JSON) maps a file NAME to the tags the real tool would print for it with
`-json -n` (dates as 'YYYY:MM:DD HH:MM:SS', GPS as signed decimals). Files not in the manifest get no tags, like a
file without metadata. It is NOT a check of real exiftool behaviour.
"""
import json
import os
import sys

args = sys.argv[1:]
if args == ["-ver"]:
    print("13.00-fake")
    sys.exit(0)
if "-json" not in args or "--" not in args:
    sys.exit(2)
with open(os.environ["FAKE_EXIFTOOL_MANIFEST"]) as fh:
    manifest = json.load(fh)
log = os.environ.get("FAKE_EXIFTOOL_LOG")
paths = args[args.index("--") + 1 :]
if log:
    with open(log, "a") as fh:
        fh.write(json.dumps(paths) + "\n")
print(json.dumps([{"SourceFile": p, **manifest.get(os.path.basename(p), {})} for p in paths]))
