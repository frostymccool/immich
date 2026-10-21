#!/usr/bin/env python3
"""copyparty event hook: forwards upload events to the immich bridge.

Runs INSIDE the copyparty container (stdlib only — no pip installs needed).
Configure on the copyparty side, globally:

    --xau f,j,t30,/hooks/immich_bridge_hook.py

or as a volflag on just one volume:

    -v /w/uploads:uploads:rw,ed:c,xau=f,j,t30,/hooks/immich_bridge_hook.py

flags: xau = execute after upload, f = fork (never blocks the upload),
j = pass upload info as JSON, t30 = 30s timeout.

The bridge URL comes from the IMMICH_BRIDGE_URL environment variable set on
the copyparty container (e.g. http://immich-bridge:8099). Delivery is
best-effort: the bridge's periodic sweep catches anything missed here.
"""

import json
import os
import sys
import time
import urllib.request


def main() -> int:
    url = os.environ.get("IMMICH_BRIDGE_URL", "").rstrip("/")
    if not url:
        print("immich_bridge_hook: IMMICH_BRIDGE_URL not set", file=sys.stderr)
        return 0  # never fail the upload

    if len(sys.argv) < 2:
        print("immich_bridge_hook: no payload (did you forget the 'j' flag?)", file=sys.stderr)
        return 0

    try:
        payload = json.loads(sys.argv[1])
    except json.JSONDecodeError as ex:
        print(f"immich_bridge_hook: bad payload: {ex}", file=sys.stderr)
        return 0

    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        url + "/hook",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                resp.read()
            return 0
        except Exception as ex:
            print(f"immich_bridge_hook: POST failed (attempt {attempt + 1}/3): {ex}", file=sys.stderr)
            time.sleep(2 * (attempt + 1))
    return 0  # sweep will pick the file up


if __name__ == "__main__":
    sys.exit(main())
