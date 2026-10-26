#!/usr/bin/env bash
# One-shot installer for the copyparty -> Immich bridge. Run it on the VM that
# runs your copyparty container. Safe to re-run: a re-run updates and rebuilds.
#
#   curl -fsSL https://raw.githubusercontent.com/frostymccool/immich/feature/copyparty-up2k-import/copyparty-immich-bridge/install.sh | bash
#
# It never edits your docker-compose.yml: everything goes in a separate
# docker-compose.override.yml next to it (delete that file to undo it all).
# Remove the bridge:  ... | bash -s -- --uninstall
set -euo pipefail

# Everything lives in main() so that, when piped from curl, bash has read the whole
# script before running any command that might itself read stdin.
main() {

COPYPARTY_DIR="${COPYPARTY_DIR:-$HOME/copyparty}"
SRC_DIR="${SRC_DIR:-$HOME/immich-bridge-src}"
REPO="${REPO:-https://github.com/frostymccool/immich.git}"
BRANCH="${BRANCH:-feature/copyparty-up2k-import}"
CONTAINER="${CONTAINER:-copyparty}"
BASE_FOLDER="${BASE_FOLDER:-Australia}"
APP_FOLDER="${APP_FOLDER:-Australia/Asia2026}"
WIDE="${WIDE:-0}"
WRITABLE="${WRITABLE:-0}"   # 1 = mount the data read-write so the page can enable move/delete after import
HOOK="${HOOK:-1}"
BRIDGE_PORT="${BRIDGE_PORT:-8099}"

MARKER="# managed by the immich-bridge installer"
OVERRIDE="$COPYPARTY_DIR/docker-compose.override.yml"
ENVFILE="$COPYPARTY_DIR/immich-bridge.env"
HOOKENV="$COPYPARTY_DIR/immich-bridge-hook.env"   # only the web-page token, for copyparty's hook

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

for tool in docker curl; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
done

if docker compose version >/dev/null 2>&1; then
  dc() { (cd "$COPYPARTY_DIR" && docker compose "$@"); }
elif command -v docker-compose >/dev/null 2>&1; then
  dc() { (cd "$COPYPARTY_DIR" && docker-compose "$@"); }
else
  die "neither 'docker compose' nor 'docker-compose' is available"
fi

if [ "${1:-}" = "--uninstall" ]; then
  say "Removing the bridge"
  if [ -f "$OVERRIDE" ] && grep -qF "$MARKER" "$OVERRIDE"; then
    rm -f "$OVERRIDE" "$ENVFILE" "$HOOKENV"
    dc up -d --remove-orphans
    echo "Done. Bridge removed; copyparty restarted without the hook."
    echo "(Its small state volume is kept; 'docker volume rm copyparty_bridge-state' deletes it.)"
  else
    echo "Nothing to remove: no installer-managed override at $OVERRIDE"
  fi
  exit 0
fi

# --- preflight ---------------------------------------------------------------
command -v git >/dev/null 2>&1 || die "git is not installed (apt install git)"
[ -f "$COPYPARTY_DIR/docker-compose.yml" ] || die "no docker-compose.yml in $COPYPARTY_DIR (set COPYPARTY_DIR=...)"
docker inspect "$CONTAINER" >/dev/null 2>&1 || die "container '$CONTAINER' not found (set CONTAINER=...)"
if [ -f "$OVERRIDE" ] && ! grep -qF "$MARKER" "$OVERRIDE"; then
  die "$OVERRIDE already exists and was not created by this installer; refusing to overwrite it"
fi

# copyparty's data mount: the first mount that is not its /cfg config dir
MOUNT_SRC="" MOUNT_DEST=""
while IFS='|' read -r msrc mdest; do
  [ -n "$mdest" ] || continue
  case "$mdest" in /cfg*) continue ;; esac
  MOUNT_SRC="$msrc"; MOUNT_DEST="$mdest"; break
done < <(docker inspect -f '{{range .Mounts}}{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' "$CONTAINER")
[ -n "$MOUNT_SRC" ] || die "could not find copyparty's data mount"
echo "copyparty data: $MOUNT_SRC -> $MOUNT_DEST (mounted into the bridge; read-only unless WRITABLE=1)"

HOST_IP="${HOST_IP:-$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')}"
[ -n "$HOST_IP" ] || HOST_IP="$(hostname -I | awk '{print $1}')"
IMMICH_URL="${IMMICH_URL:-http://$HOST_IP:2283}"

if [ "$HOOK" = "1" ] && grep -qE '^[[:space:]]+command:' "$COPYPARTY_DIR/docker-compose.yml"; then
  echo "Your copyparty compose already sets 'command:' - skipping the instant hook (the 15-minute sweep still works)."
  HOOK=0
fi

if [ "$WIDE" = "1" ]; then WATCH="$MOUNT_DEST/$BASE_FOLDER"; else WATCH="$MOUNT_DEST/$APP_FOLDER"; fi
PRIORITY="$MOUNT_DEST/$APP_FOLDER"
if [ "$WRITABLE" = "1" ]; then MOUNT_MODE=rw; else MOUNT_MODE=ro; fi

# --- bridge source -------------------------------------------------------------
say "Fetching the bridge (branch $BRANCH)"
if [ -d "$SRC_DIR/.git" ]; then
  git -C "$SRC_DIR" fetch --depth 1 origin "$BRANCH"
  git -C "$SRC_DIR" reset --hard FETCH_HEAD
else
  git clone --depth 1 --filter=blob:none --sparse --branch "$BRANCH" "$REPO" "$SRC_DIR"
  git -C "$SRC_DIR" sparse-checkout set copyparty-immich-bridge
fi
BRIDGE_DIR="$SRC_DIR/copyparty-immich-bridge"
[ -f "$BRIDGE_DIR/Dockerfile" ] || die "bridge sources missing in $BRIDGE_DIR"

# --- Immich API key --------------------------------------------------------------
KEY="${IMMICH_API_KEY:-}"
if [ -z "$KEY" ] && [ -f "$ENVFILE" ]; then
  KEY="$(sed -n 's/^IMMICH_API_KEY=//p' "$ENVFILE" | head -n1)"
fi
if [ -z "$KEY" ]; then
  echo
  echo "Create an API key in Immich: Account Settings > API Keys (all permissions is simplest)."
  if ! read -r -s -p "Paste the Immich API key (input hidden): " KEY </dev/tty 2>/dev/null; then
    die "no terminal to ask on; re-run with IMMICH_API_KEY=... in front"
  fi
  echo
fi
[ -n "$KEY" ] || die "no API key given"

# Token for the bridge's web page and its /hook endpoint: reused on re-runs so links keep working.
TOKEN="${BRIDGE_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f "$ENVFILE" ]; then
  TOKEN="$(sed -n 's/^BRIDGE_TOKEN=//p' "$ENVFILE" | head -n1)"
fi
if [ -z "$TOKEN" ]; then
  TOKEN="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
fi
[ "${#TOKEN}" -ge 16 ] || die "could not create a web-page token (set BRIDGE_TOKEN=... of at least 16 characters)"

say "Checking Immich at $IMMICH_URL"
curl -fsS -m 10 "$IMMICH_URL/api/server/ping" >/dev/null || die "cannot reach Immich at $IMMICH_URL (set IMMICH_URL=...)"
curl -fsS -m 10 -H "x-api-key: $KEY" "$IMMICH_URL/api/users/me" >/dev/null || die "Immich rejected that API key"
echo "Immich reachable, API key accepted."

umask 077
printf 'IMMICH_API_KEY=%s\nBRIDGE_TOKEN=%s\n' "$KEY" "$TOKEN" > "$ENVFILE"
printf 'IMMICH_BRIDGE_TOKEN=%s\n' "$TOKEN" > "$HOOKENV"
umask 022

# --- compose override ------------------------------------------------------------
write_override() {
  {
    echo "$MARKER (delete this file to undo; re-run the installer to update)"
    echo "services:"
    if [ "$1" = "1" ]; then
      cat <<EOF
  $CONTAINER:
    volumes:
      - $BRIDGE_DIR/hook/immich_bridge_hook.py:/hooks/immich_bridge_hook.py:ro
    env_file:
      - ./immich-bridge-hook.env
    environment:
      IMMICH_BRIDGE_URL: http://immich-bridge:8099
    command: ["--xau", "f,j,t30,/hooks/immich_bridge_hook.py"]
EOF
    fi
    cat <<EOF
  immich-bridge:
    build: $BRIDGE_DIR
    container_name: immich-bridge
    restart: unless-stopped
    ports:
      - "$BRIDGE_PORT:8099"
    env_file:
      - ./immich-bridge.env
    environment:
      IMMICH_URL: $IMMICH_URL
      WATCH_DIRS: $WATCH
      PRIORITY_DIRS: $PRIORITY
      BROWSE_ROOTS: $MOUNT_DEST
    volumes:
      - $MOUNT_SRC:$MOUNT_DEST:$MOUNT_MODE
      - bridge-state:/data
volumes:
  bridge-state:
EOF
  } > "$OVERRIDE"
}

say "Starting the bridge"
write_override "$HOOK"
dc up -d --build --remove-orphans

if [ "$HOOK" = "1" ]; then
  sleep 10
  state="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
  if [ "$state" != "running" ]; then
    echo "copyparty did not stay up with the instant hook ($state); removing the hook and retrying."
    write_override 0
    dc up -d --remove-orphans
    HOOK=0
  fi
fi

say "Waiting for the bridge to come up"
ok=0
for _ in $(seq 1 30); do
  if curl -fsS -m 3 "http://127.0.0.1:$BRIDGE_PORT/healthz" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
if [ "$ok" != "1" ]; then
  docker logs --tail 40 immich-bridge 2>&1 || true
  die "the bridge did not become healthy; log above"
fi

say "Installed"
echo "Watching:        $WATCH"
echo "Imported first:  $PRIORITY"
if [ "$HOOK" = "1" ]; then echo "Instant import:  on (copyparty hook)"; else echo "Instant import:  off (the sweep checks every 15 minutes)"; fi
[ "$WIDE" = "1" ] || echo "Only the app's folder is watched. To also import the rest of '$BASE_FOLDER', re-run with WIDE=1 in front."
echo
echo "Settings page:   http://$HOST_IP:$BRIDGE_PORT/#token=$TOKEN"
echo "                 (open that link once; the browser remembers it. Choose folders, see logs, scan now.)"
echo "                 Folders you save there are kept and win over the ones above; 'Reset to installer defaults' undoes that."
echo
echo "LAST STEP, on your phone: Settings > copyparty > Import Bridge > URL:  http://$HOST_IP:$BRIDGE_PORT"
}

main "$@"
