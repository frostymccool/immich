#!/usr/bin/env bash
# One-shot installer for the copyparty -> Immich bridge. Run it on the VM that
# runs your copyparty container. Safe to re-run: a re-run updates and rebuilds.
#
#   curl -fsSL https://raw.githubusercontent.com/frostymccool/immich/feature/copyparty-up2k-import/copyparty-immich-bridge/install.sh | bash
#
# It never edits your docker-compose.yml: everything goes in a separate
# docker-compose.override.yml next to it (delete that file to undo it all).
# Remove the bridge:  ... | bash -s -- --uninstall
# Options are environment variables and go in front of `bash` (NOT in front of curl), for example:
#   curl -fsSL <url> | EXTRA_COPYPARTY=copyparty-2 APP_FOLDER=Trips/Summer2026 bash
set -euo pipefail

# Everything lives in main() so that, when piped from curl, bash has read the whole
# script before running any command that might itself read stdin.
main() {

COPYPARTY_DIR="${COPYPARTY_DIR:-$HOME/copyparty}"
SRC_DIR="${SRC_DIR:-$HOME/immich-bridge-src}"
REPO="${REPO:-https://github.com/frostymccool/immich.git}"
BRANCH="${BRANCH:-feature/copyparty-up2k-import}"
CONTAINER="${CONTAINER:-copyparty}"
# Folder the phone app uploads into, RELATIVE to copyparty's data folder (e.g. Trips/Summer2026). Asked
# for on a first install, then remembered by re-runs. "." = everything under the data folder.
APP_FOLDER="${APP_FOLDER:-}"
# The wider folder WIDE=1 watches instead; default: the folder containing APP_FOLDER.
BASE_FOLDER="${BASE_FOLDER:-}"
WIDE="${WIDE:-0}"
WRITABLE="${WRITABLE:-0}"   # 1 = mount the data read-write so the page can enable move/delete after import
HOOK="${HOOK:-1}"
BRIDGE_PORT="${BRIDGE_PORT:-8099}"
# More copyparty containers whose data folders the bridge should also see (read-only unless WRITABLE=1), as a
# comma list of container names, e.g. EXTRA_COPYPARTY=copyparty-alex,copyparty-kids . If a container has several
# data mounts, pick one with name=/host/folder. Remembered by re-runs; EXTRA_COPYPARTY=none forgets them.
EXTRA_COPYPARTY="${EXTRA_COPYPARTY:-}"

MARKER="# managed by the immich-bridge installer"
SWEEP_NOTE="15 minutes"
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
    rm -f "$OVERRIDE" "$ENVFILE" "$HOOKENV" "$COPYPARTY_DIR/update-bridge.sh"
    dc up -d --remove-orphans
    echo "Done. Bridge removed; copyparty restarted without the hook."
    echo "(Its state volume is kept; it holds the import records and every person's Immich API key (users.json, plaintext)."
    echo " 'docker volume rm copyparty_bridge-state' deletes it - do that if you want the keys gone.)"
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

# copyparty's data mount. Docker lists a container's mounts alphabetically, and on a RE-run the list also
# holds the hook script this installer mounted last time (/hooks/...), so "the first mount" is not good
# enough. Skip config/hook/file mounts, and on a re-run prefer the mount we used last time.
MOUNT_SRC="" MOUNT_DEST=""
mapfile -t MOUNTS < <(docker inspect -f '{{range .Mounts}}{{.Type}}|{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' "$CONTAINER")
PREV_ROOT=""
if [ -f "$OVERRIDE" ] && grep -qF "$MARKER" "$OVERRIDE"; then
  PREV_ROOT="$(sed -n 's/^[[:space:]]*BROWSE_ROOTS:[[:space:]]*//p' "$OVERRIDE" | head -n1 | cut -d, -f1)"
fi
for pass in prev auto; do
  for m in "${MOUNTS[@]}"; do
    IFS='|' read -r mtype msrc mdest <<<"$m"
    [ -n "$mdest" ] || continue
    case "$mdest" in /cfg|/cfg/*|/hooks|/hooks/*) continue ;; esac
    case "$mtype" in bind|volume) ;; *) continue ;; esac
    [ -f "$msrc" ] && continue
    if [ "$pass" = prev ] && [ "$mdest" != "$PREV_ROOT" ]; then continue; fi
    MOUNT_SRC="$msrc"; MOUNT_DEST="$mdest"; break 2
  done
done
[ -n "$MOUNT_SRC" ] || die "could not find copyparty's data mount"
echo "copyparty data: $MOUNT_SRC -> $MOUNT_DEST (mounted into the bridge; read-only unless WRITABLE=1)"

HOST_IP="${HOST_IP:-$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')}"
[ -n "$HOST_IP" ] || HOST_IP="$(hostname -I | awk '{print $1}')"
IMMICH_URL="${IMMICH_URL:-http://$HOST_IP:2283}"

if [ "$HOOK" = "1" ] && grep -qE '^[[:space:]]+command:' "$COPYPARTY_DIR/docker-compose.yml"; then
  echo "Your copyparty compose already sets 'command:' - skipping the instant hook (the 15-minute sweep still works)."
  HOOK=0
fi

# --- which folder does the phone app upload into? ----------------------------------
# 1) explicit APP_FOLDER=..., 2) the value a previous run of this installer wrote, 3) ask once.
if [ -z "$APP_FOLDER" ] && [ -f "$OVERRIDE" ] && grep -qF "$MARKER" "$OVERRIDE"; then
  prev="$(sed -n 's/^[[:space:]]*PRIORITY_DIRS:[[:space:]]*//p' "$OVERRIDE" | head -n1)"
  case "$prev" in
    "$MOUNT_DEST"/*) APP_FOLDER="${prev#"$MOUNT_DEST"/}"; echo "Keeping the folder from your last install: $APP_FOLDER" ;;
  esac
fi
if [ -z "$APP_FOLDER" ]; then
  echo
  echo "Which folder does the phone app upload into?"
  # Offer the folders that actually exist (newest first - the one you just uploaded into is usually on top).
  CHOICES=()
  if [ -d "$MOUNT_SRC" ] && [ -r "$MOUNT_SRC" ]; then
    mapfile -t CHOICES < <(cd "$MOUNT_SRC" && find . -mindepth 1 -maxdepth 2 -type d ! -path '*/.*' -printf '%T@ %P\n' 2>/dev/null \
      | sort -rn | head -n 20 | cut -d' ' -f2-)
  fi
  if [ "${#CHOICES[@]}" -gt 0 ]; then
    n=0
    for c in "${CHOICES[@]}"; do n=$((n + 1)); printf '  %2d) %s\n' "$n" "$c"; done
    echo "Type the number, or type a folder path, or just press Enter to watch everything."
  else
    echo "Type it relative to copyparty's data folder (inside $MOUNT_DEST), for example  Trips/Summer2026 ,"
    echo "or just press Enter to watch everything."
  fi
  if ! read -r -p "Folder: " APP_FOLDER </dev/tty 2>/dev/null; then
    die "no terminal to ask on; re-run with APP_FOLDER=... in front (or APP_FOLDER=. to watch everything)"
  fi
  if [[ "$APP_FOLDER" =~ ^[0-9]+$ ]] && [ "$APP_FOLDER" -ge 1 ] && [ "$APP_FOLDER" -le "${#CHOICES[@]}" ]; then
    APP_FOLDER="${CHOICES[$((APP_FOLDER - 1))]}"
  fi
  [ -n "$APP_FOLDER" ] || APP_FOLDER="."
fi
APP_FOLDER="${APP_FOLDER#/}"; APP_FOLDER="${APP_FOLDER%/}"; [ -n "$APP_FOLDER" ] || APP_FOLDER="."
if [ -z "$BASE_FOLDER" ]; then
  case "$APP_FOLDER" in */*) BASE_FOLDER="${APP_FOLDER%/*}" ;; *) BASE_FOLDER="." ;; esac
fi
BASE_FOLDER="${BASE_FOLDER#/}"; BASE_FOLDER="${BASE_FOLDER%/}"; [ -n "$BASE_FOLDER" ] || BASE_FOLDER="."

under_mount() { if [ "$1" = "." ]; then printf '%s' "$MOUNT_DEST"; else printf '%s/%s' "$MOUNT_DEST" "$1"; fi; }
if [ "$WIDE" = "1" ]; then WATCH="$(under_mount "$BASE_FOLDER")"; else WATCH="$(under_mount "$APP_FOLDER")"; fi
# A priority folder only makes sense when it is narrower than what is watched.
PRIORITY=""
PRIORITY_LINE="      # PRIORITY_DIRS: not set (the whole data folder is watched, nothing is imported first)"
if [ "$APP_FOLDER" != "." ]; then
  PRIORITY="$(under_mount "$APP_FOLDER")"
  PRIORITY_LINE="      PRIORITY_DIRS: $PRIORITY"
fi
if [ "$WRITABLE" = "1" ]; then MOUNT_MODE=rw; else MOUNT_MODE=ro; fi

# --- more copyparty containers (optional) ---------------------------------------------
# Each one's data folder is mounted at /cp/<name>. Two copyparty containers can both call their volume /w, so the
# bridge is told how to translate each one's hook paths (SOURCE_MAPS, matched by the IMMICH_BRIDGE_SOURCE name).
EXTRA_FROM_OVERRIDE=0
if [ -z "$EXTRA_COPYPARTY" ] && [ -f "$OVERRIDE" ] && grep -qF "$MARKER" "$OVERRIDE"; then
  EXTRA_COPYPARTY="$(sed -n 's/^# EXTRA_COPYPARTY:[[:space:]]*//p' "$OVERRIDE" | head -n1)"
  EXTRA_FROM_OVERRIDE=1
fi
[ "$EXTRA_COPYPARTY" != "none" ] || EXTRA_COPYPARTY=""
EXTRA_REMEMBERED="$EXTRA_FROM_OVERRIDE"   # 1 = the list came from the previous install, not from this command
case "$EXTRA_COPYPARTY" in *[[:cntrl:]]*) die "EXTRA_COPYPARTY contains control characters" ;; esac
EXTRA_VOLUMES="" EXTRA_MAPS="" EXTRA_ROOTS="$MOUNT_DEST" EXTRA_NAMES=() EXTRA_DESTS=()
SEEN_SRCS=("$(readlink -f "$MOUNT_SRC" 2>/dev/null || echo "$MOUNT_SRC")")
EXTRA_LIST=()
[ -z "$EXTRA_COPYPARTY" ] || IFS=',' read -r -a EXTRA_LIST <<<"$EXTRA_COPYPARTY"
EXTRA_KEPT=() EXTRA_DONE=","
# (the loop is skipped when there are no extras: an empty array under set -u breaks bash 4.3 and older)
if [ "${#EXTRA_LIST[@]}" -gt 0 ]; then
for entry in "${EXTRA_LIST[@]}"; do
  entry="${entry// /}"
  [ -n "$entry" ] || continue
  xname="${entry%%=*}"; xhost=""
  case "$entry" in *=*) xhost="${entry#*=}" ;; esac
  [[ "$xname" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "EXTRA_COPYPARTY: '$xname' is not a usable container name"
  case "$EXTRA_DONE" in *",$xname,"*) continue ;; esac   # listed twice
  EXTRA_DONE="$EXTRA_DONE$xname,"
  if ! docker inspect "$xname" >/dev/null 2>&1; then
    if [ "$EXTRA_REMEMBERED" = 1 ]; then
      echo "NOTE: the extra copyparty '$xname' from an earlier install no longer exists - dropping it (its folders will show as missing on the People tab)."
      continue
    fi
    die "EXTRA_COPYPARTY: container '$xname' was not found (docker ps shows the names; EXTRA_COPYPARTY=none forgets all extras)"
  fi
  [ "$xname" != "$CONTAINER" ] || die "EXTRA_COPYPARTY: '$xname' is the main copyparty container already"
  xsrc="" xdest=""
  mapfile -t XM < <(docker inspect -f '{{range .Mounts}}{{.Type}}|{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' "$xname")
  for m in "${XM[@]}"; do
    IFS='|' read -r mtype msrc mdest <<<"$m"
    [ -n "$mdest" ] || continue
    case "$mdest" in /cfg|/cfg/*|/hooks|/hooks/*) continue ;; esac
    case "$mtype" in bind|volume) ;; *) continue ;; esac
    [ -f "$msrc" ] && continue
    if [ -n "$xhost" ] && [ "$msrc" != "$xhost" ]; then continue; fi
    xsrc="$msrc"; xdest="$mdest"; break
  done
  [ -n "$xsrc" ] || die "EXTRA_COPYPARTY: could not find a data mount in '$xname'${xhost:+ matching $xhost} (name=/host/folder picks one)"
  [[ "$xsrc" =~ ^[A-Za-z0-9_./@+-]+$ && "$xdest" =~ ^[A-Za-z0-9_./@+-]+$ ]] || die "EXTRA_COPYPARTY: '$xname' has a data path with unusual characters ($xsrc -> $xdest); use letters, digits and _ . / - only"
  real="$(readlink -f "$xsrc" 2>/dev/null || echo "$xsrc")"
  for seen in "${SEEN_SRCS[@]}"; do
    case "$real/" in "$seen"/*) die "EXTRA_COPYPARTY: $xname's data folder ($xsrc) is the same as, or inside, another copyparty's ($seen): one file would have two owners. Pick separate folders." ;; esac
    case "$seen/" in "$real"/*) die "EXTRA_COPYPARTY: $xname's data folder ($xsrc) contains another copyparty's ($seen): one file would have two owners. Pick separate folders." ;; esac
  done
  SEEN_SRCS+=("$real")
  EXTRA_NAMES+=("$xname"); EXTRA_DESTS+=("$xdest"); EXTRA_KEPT+=("$entry")
  EXTRA_VOLUMES="$EXTRA_VOLUMES      - $xsrc:/cp/$xname:$MOUNT_MODE
"
  EXTRA_ROOTS="$EXTRA_ROOTS,/cp/$xname"
  EXTRA_MAPS="${EXTRA_MAPS:+$EXTRA_MAPS,}$xname|$xdest=/cp/$xname"
  echo "extra copyparty '$xname': $xsrc -> /cp/$xname (its own path $xdest is translated)"
done
fi
if [ "${#EXTRA_KEPT[@]}" -gt 0 ]; then EXTRA_COPYPARTY="$(IFS=,; echo "${EXTRA_KEPT[*]}")"; else EXTRA_COPYPARTY=""; fi
if [ -n "$EXTRA_MAPS" ]; then EXTRA_MAPS_LINE="      SOURCE_MAPS: \"$EXTRA_MAPS\""; else EXTRA_MAPS_LINE="      # SOURCE_MAPS: not set (no extra copyparty)"; fi

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
# which commit this is, shown in the bridge page header (so "what am I running?" has an answer)
BUILD_ID="$(git -C "$SRC_DIR" log -1 --format='%h %cd' --date=short 2>/dev/null | tr -d '"' || true)"
[ -n "$BUILD_ID" ] || BUILD_ID="unknown"
UPDATER="$COPYPARTY_DIR/update-bridge.sh"
[ -f "$BRIDGE_DIR/Dockerfile" ] || die "bridge sources missing in $BRIDGE_DIR"
# a one-command updater, kept next to copyparty's compose file
if [ -f "$BRIDGE_DIR/update-bridge.sh" ]; then
  cp "$BRIDGE_DIR/update-bridge.sh" "$UPDATER" && chmod +x "$UPDATER" && echo "Saved the updater: $UPDATER"
fi

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
# Folder-named albums need album permissions on the key. Warn (never fail) if it clearly lacks them.
perms="$(curl -fsS -m 10 -H "x-api-key: $KEY" "$IMMICH_URL/api/api-keys/me" 2>/dev/null || true)"
if [ -n "$perms" ] && ! printf '%s' "$perms" | grep -q '"all"'; then
  missing=""
  for p in album.read album.create albumAsset.create; do
    printf '%s' "$perms" | grep -q "\"$p\"" || missing="$missing $p"
  done
  if [ -n "$missing" ]; then
    echo "NOTE: this API key lacks album permissions (missing:$missing)."
    echo "      Imports will work, but files will NOT be added to folder albums. For albums, create a key with"
    echo "      all permissions in Immich (Account Settings > API Keys) and re-run with IMMICH_API_KEY=... in front."
  fi
fi

umask 077
printf 'IMMICH_API_KEY=%s\nBRIDGE_TOKEN=%s\n' "$KEY" "$TOKEN" > "$ENVFILE"
printf 'IMMICH_BRIDGE_TOKEN=%s\n' "$TOKEN" > "$HOOKENV"
umask 022

# --- compose override ------------------------------------------------------------
write_override() {
  {
    echo "$MARKER (delete this file to undo; re-run the installer to update)"
    [ -z "$EXTRA_COPYPARTY" ] || echo "# EXTRA_COPYPARTY: $EXTRA_COPYPARTY"
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
$PRIORITY_LINE
      BROWSE_ROOTS: $EXTRA_ROOTS
$EXTRA_MAPS_LINE
      BRIDGE_BUILD: "$BUILD_ID"
    volumes:
      - $MOUNT_SRC:$MOUNT_DEST:$MOUNT_MODE
${EXTRA_VOLUMES}      - bridge-state:/data
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
echo "Imported first:  ${PRIORITY:-nothing in particular}"
if [ "$HOOK" = "1" ]; then echo "Instant import:  on (copyparty hook)"; else echo "Instant import:  off (the sweep checks every 15 minutes)"; fi
if [ "$WIDE" != "1" ] && [ "$APP_FOLDER" != "." ]; then
  echo "Only the app's folder is watched. To also import the rest of '$BASE_FOLDER', re-run with WIDE=1 in front."
fi
if [ "${#EXTRA_NAMES[@]}" -gt 0 ]; then
  echo
  echo "More than one copyparty - the bridge can now see:"
  for i in "${!EXTRA_NAMES[@]}"; do echo "  /cp/${EXTRA_NAMES[$i]}   (that container's ${EXTRA_DESTS[$i]})"; done
  echo "Open the People tab on the settings page to give each person their Immich API key and folder"
  echo "(choose the folder under /cp/<name> for people whose files live on that copyparty)."
  echo
  echo "Instant import from the extra copyparty containers needs the hook there too. Add this under the copyparty"
  echo "service in EACH one's own compose file (this installer does not edit other compose projects). Without it the"
  echo "periodic scan still imports everything, just up to $SWEEP_NOTE later:"
  for n in "${EXTRA_NAMES[@]}"; do
    echo
    echo "  # $n  (the token below is the same secret as in $HOOKENV - keep this compose file private)"
    echo "    volumes:"
    echo "      - $BRIDGE_DIR/hook/immich_bridge_hook.py:/hooks/immich_bridge_hook.py:ro"
    echo "    environment:"
    echo "      IMMICH_BRIDGE_URL: http://$HOST_IP:$BRIDGE_PORT"
    echo "      IMMICH_BRIDGE_SOURCE: $n"
    echo "      IMMICH_BRIDGE_TOKEN: $TOKEN"
    echo "    command: [\"--xau\", \"f,j,t30,/hooks/immich_bridge_hook.py\"]"
  done
fi
echo
echo "Settings page:   http://$HOST_IP:$BRIDGE_PORT/#token=$TOKEN"
echo "                 (open that link once; the browser remembers it. Choose folders, see logs, scan now.)"
echo "                 Folders you save there are kept and win over the ones above; 'Reset to installer defaults' undoes that."
echo
echo "To update later, run:  $UPDATER   (it checks it is the latest first; add --check to only look)"
echo
echo "LAST STEP, on your phone: Settings > copyparty > Import Bridge > URL:  http://$HOST_IP:$BRIDGE_PORT"
}

main "$@"
