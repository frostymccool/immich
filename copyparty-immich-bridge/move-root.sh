#!/usr/bin/env bash
# Moves copyparty's data folder (and the bridge with it) safely.
#
#   curl -fsSL https://raw.githubusercontent.com/frostymccool/immich/feature/copyparty-up2k-import/copyparty-immich-bridge/move-root.sh \
#     | bash -s -- --data /mnt/uploads/Photos --app-folder Trips/Summer2026          # shows the plan, changes nothing
#   ... | bash -s -- --data /mnt/uploads/Photos --app-folder Trips/Summer2026 --apply  # does it
#   ... | bash -s -- --rollback ~/copyparty/backups/move-root-YYYYMMDD-HHMMSS --apply  # undoes it
#
# It never moves, copies or deletes your photos/videos. YOU move the folders on the share first; this script then
# repoints everything that refers to them: copyparty's compose file + config, the bridge, and the bridge's memory of
# what it already imported (so nothing is re-hashed just because a path changed). Every file it edits is backed up first.
#
# --data PATH         the host folder copyparty should serve (becomes /w in the containers)
# --app-folder REL    the folder inside it that the phone app uploads into ("." = the whole folder)
# --root-sub REL      optional: copyparty's web root is this subfolder of --data instead of all of it
# --no-keep-history   do not re-point the bridge's import records (everything is re-checked once; nothing re-uploads)
# --apply             actually do it (without it you only get the plan)
#
# A saved copy of this file replaces itself with the latest published version before it does anything else
# (set MOVE_ROOT_NO_UPDATE=1 to skip that). Run straight from curl, it is already the latest.
set -euo pipefail

SELF_URL="${MOVE_ROOT_URL:-https://raw.githubusercontent.com/frostymccool/immich/feature/copyparty-up2k-import/copyparty-immich-bridge/move-root.sh}"

# Fetches the latest move-root.sh; if it differs from this saved copy, replaces the copy and re-runs it with the
# same arguments. Any problem (offline, an error page, a broken download) just carries on with this copy.
self_update() {
  [ "${MOVE_ROOT_NO_UPDATE:-0}" = 1 ] && return 0
  [ "${MOVE_ROOT_UPDATED:-0}" = 1 ] && return 0
  local self="${BASH_SOURCE[0]:-}"
  [ -n "$self" ] && [ -f "$self" ] || return 0   # piped from curl: this IS the latest
  command -v curl >/dev/null 2>&1 || { echo "(curl is missing: cannot check for a newer move-root.sh)"; return 0; }
  local tmp; tmp="$(mktemp)"
  if ! curl -fsSL -m 15 -o "$tmp" "$SELF_URL" 2>/dev/null || [ ! -s "$tmp" ]; then
    echo "(could not check for a newer move-root.sh; using this copy)"; rm -f "$tmp"; return 0
  fi
  if ! head -n1 "$tmp" | grep -q '^#!/usr/bin/env bash' || ! grep -q 'move-root.sh' "$tmp" || ! bash -n "$tmp" 2>/dev/null; then
    echo "(the downloaded move-root.sh looks wrong; using this copy)"; rm -f "$tmp"; return 0
  fi
  if cmp -s "$tmp" "$self"; then rm -f "$tmp"; return 0; fi
  echo "Updating move-root.sh to the latest version..."
  # write a new file and move it over the old one, so this running copy is never edited while bash reads it
  if cp "$tmp" "$self.new" 2>/dev/null && chmod --reference="$self" "$self.new" 2>/dev/null && mv "$self.new" "$self" 2>/dev/null; then
    rm -f "$tmp"
    MOVE_ROOT_UPDATED=1 exec bash "$self" "$@"
  fi
  rm -f "$self.new"
  echo "(could not save the update next to this file; running the latest from a temporary copy)"
  MOVE_ROOT_UPDATED=1 exec bash "$tmp" "$@"
}

main() {
self_update "$@"
COPYPARTY_DIR="${COPYPARTY_DIR:-$HOME/copyparty}"
SRC_DIR="${SRC_DIR:-$HOME/immich-bridge-src}"
CONTAINER="${CONTAINER:-copyparty}"
BRIDGE="${BRIDGE:-immich-bridge}"
BRIDGE_PORT="${BRIDGE_PORT:-8099}"
OVERRIDE="$COPYPARTY_DIR/docker-compose.override.yml"
ENVFILE="$COPYPARTY_DIR/immich-bridge.env"
HOOKENV="$COPYPARTY_DIR/immich-bridge-hook.env"

DATA="" APP_FOLDER="" ROOT_SUB="" APPLY=0 ROLLBACK="" KEEP_HISTORY=1
while [ $# -gt 0 ]; do
  case "$1" in
    --data) DATA="${2:-}"; shift 2 ;;
    --app-folder) APP_FOLDER="${2:-}"; shift 2 ;;
    --root-sub) ROOT_SUB="${2:-}"; shift 2 ;;
    --rollback) ROLLBACK="${2:-}"; shift 2 ;;
    --no-keep-history) KEEP_HISTORY=0; shift ;;
    --apply) APPLY=1; shift ;;
    -h|--help)
      cat <<'USAGE'
move-root.sh --data HOST_PATH --app-folder REL [--root-sub REL] [--no-keep-history] [--apply]
move-root.sh --rollback BACKUP_FOLDER --apply
Without --apply it only shows the plan. Your photos/videos are never moved or deleted; every edited file is backed up.
USAGE
      exit 0 ;;
    *) printf 'unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
done

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
if docker compose version >/dev/null 2>&1; then
  dc() { (cd "$COPYPARTY_DIR" && docker compose "$@"); }
elif command -v docker-compose >/dev/null 2>&1; then
  dc() { (cd "$COPYPARTY_DIR" && docker-compose "$@"); }
else
  die "neither 'docker compose' nor 'docker-compose' is available"
fi
trim_slashes() { local v="$1"; v="${v#/}"; v="${v%/}"; [ -n "$v" ] || v="."; printf '%s' "$v"; }

# --- find the pieces -----------------------------------------------------------------------------
docker inspect "$CONTAINER" >/dev/null 2>&1 || die "container '$CONTAINER' not found (set CONTAINER=...)"
COMPOSE=""
for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
  [ -f "$COPYPARTY_DIR/$f" ] && { COMPOSE="$COPYPARTY_DIR/$f"; break; }
done
[ -n "$COMPOSE" ] || die "no compose file in $COPYPARTY_DIR (set COPYPARTY_DIR=...)"

OLD_DATA="" DEST="" CFG_SRC=""
mapfile -t MOUNTS < <(docker inspect -f '{{range .Mounts}}{{.Type}}|{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' "$CONTAINER")
for m in "${MOUNTS[@]}"; do
  IFS='|' read -r mtype msrc mdest <<<"$m"
  [ -n "$mdest" ] || continue
  case "$mdest" in
    /cfg) CFG_SRC="$msrc"; continue ;;
    /cfg/*|/hooks|/hooks/*) continue ;;
  esac
  case "$mtype" in bind|volume) ;; *) continue ;; esac
  [ -f "$msrc" ] && continue
  if [ -z "$OLD_DATA" ]; then OLD_DATA="$msrc"; DEST="$mdest"; fi
done
[ -n "$OLD_DATA" ] || die "could not find copyparty's data mount"

CONF=""
if [ -n "$CFG_SRC" ]; then
  for f in "$CFG_SRC"/*.conf; do
    [ -f "$f" ] && grep -q '^\[/' "$f" && { CONF="$f"; break; }
  done
fi

# --- rollback ------------------------------------------------------------------------------------
if [ -n "$ROLLBACK" ]; then
  [ -d "$ROLLBACK" ] || die "backup folder not found: $ROLLBACK"
  say "Rollback from $ROLLBACK"
  for f in "$ROLLBACK"/*; do
    case "$(basename "$f")" in
      compose.bak) echo "  restore $COMPOSE" ;;
      conf.bak) echo "  restore $CONF" ;;
      override.bak) echo "  restore $OVERRIDE" ;;
      immich-bridge.env.bak) echo "  restore $ENVFILE" ;;
      immich-bridge-hook.env.bak) echo "  restore $HOOKENV" ;;
    esac
  done
  [ "$APPLY" = 1 ] || { echo; echo "Nothing changed. Add --apply to do this."; return 0; }
  [ -f "$ROLLBACK/compose.bak" ] && cat "$ROLLBACK/compose.bak" > "$COMPOSE"
  [ -f "$ROLLBACK/conf.bak" ] && [ -n "$CONF" ] && cat "$ROLLBACK/conf.bak" > "$CONF"
  [ -f "$ROLLBACK/override.bak" ] && cat "$ROLLBACK/override.bak" > "$OVERRIDE"
  [ -f "$ROLLBACK/immich-bridge.env.bak" ] && cat "$ROLLBACK/immich-bridge.env.bak" > "$ENVFILE"
  [ -f "$ROLLBACK/immich-bridge-hook.env.bak" ] && cat "$ROLLBACK/immich-bridge-hook.env.bak" > "$HOOKENV"
  if [ -f "$ROLLBACK/state-restore.txt" ]; then
    img="$(docker inspect -f '{{.Config.Image}}' "$BRIDGE" 2>/dev/null || true)"
    if [ -n "$img" ]; then
      docker stop "$BRIDGE" >/dev/null 2>&1 || true
      docker run --rm --volumes-from "$BRIDGE" --entrypoint python "$img" -c \
        "import os,shutil; p='/data/state.db'; b=p+'.pre-move'; (shutil.copy(b,p), print('bridge history restored')) if os.path.exists(b) else print('no saved bridge history to restore')"
    fi
  fi
  dc up -d --force-recreate
  say "Rolled back. The containers were recreated from the restored files."
  return 0
fi

# --- validate the request -----------------------------------------------------------------------
[ -n "$DATA" ] || die "give the new folder with --data /host/path (see --help)"
[ -n "$APP_FOLDER" ] || die "give the phone app's upload folder with --app-folder REL (use . for the whole folder)"
DATA="${DATA%/}"; [ -n "$DATA" ] || DATA="/"
case "$DATA" in /*) ;; *) die "--data must be an absolute path" ;; esac
[ -d "$DATA" ] || die "$DATA does not exist or is not a folder on this machine"
APP_FOLDER="$(trim_slashes "$APP_FOLDER")"
ROOT_SUB="$(trim_slashes "${ROOT_SUB:-.}")"
[ "$APP_FOLDER" = "." ] || [ -d "$DATA/$APP_FOLDER" ] || die "$DATA/$APP_FOLDER does not exist: move the folders there first, then re-run"
[ "$ROOT_SUB" = "." ] || [ -d "$DATA/$ROOT_SUB" ] || die "$DATA/$ROOT_SUB does not exist"

NEW_ROOT="$DEST"; [ "$ROOT_SUB" = "." ] || NEW_ROOT="$DEST/$ROOT_SUB"
NEW_WATCH="$DEST"; [ "$APP_FOLDER" = "." ] || NEW_WATCH="$DEST/$APP_FOLDER"
UPLOAD_PATH="/"
if [ "$ROOT_SUB" != "." ]; then
  case "$APP_FOLDER" in
    "$ROOT_SUB") UPLOAD_PATH="/" ;;
    "$ROOT_SUB"/*) UPLOAD_PATH="/${APP_FOLDER#"$ROOT_SUB"/}/" ;;
    *) die "the app folder ($APP_FOLDER) is outside copyparty's web root ($ROOT_SUB): uploads would not land where the bridge watches" ;;
  esac
elif [ "$APP_FOLDER" != "." ]; then
  UPLOAD_PATH="/$APP_FOLDER/"
fi

OLD_ROOT="" OLD_WATCH="" OLD_WATCH_COUNT=0
if [ -n "$CONF" ]; then
  OLD_ROOT="$(awk '/^\[\/\][[:space:]]*(#.*)?$/{s=1;next} /^\[/{s=0} s && !/^[[:space:]]*(#|$)/{sub(/^[[:space:]]+/,""); sub(/[[:space:]]+#.*$/,""); print; exit}' "$CONF")"
  [ -n "$OLD_ROOT" ] || die "found $CONF but no folder line under its [/] section; edit it by hand to '  $NEW_ROOT' and re-run with the compose step only"
fi
if [ -f "$OVERRIDE" ]; then
  OLD_WATCH="$(sed -n 's/^[[:space:]]*WATCH_DIRS:[[:space:]]*//p' "$OVERRIDE" | head -n1)"
  OLD_WATCH_COUNT="$(printf '%s' "$OLD_WATCH" | tr ',' '\n' | grep -c . || true)"
fi

FSTYPE="$(findmnt -no FSTYPE -T "$DATA" 2>/dev/null | head -n1 || true)"
HIST_NEEDED=0
case "$FSTYPE" in cifs|smb3|smbfs|nfs|nfs4|fuse*|9p) HIST_NEEDED=1 ;; esac
HIST_PRESENT=0
[ -n "$CONF" ] && grep -q '^[[:space:]]*hist:' "$CONF" && HIST_PRESENT=1

if [ "$OLD_DATA" = "$DATA" ] && [ "$OLD_ROOT" = "$NEW_ROOT" ] && [ "$OLD_WATCH" = "$NEW_WATCH" ]; then
  die "nothing to change: copyparty already serves $DATA with the root $NEW_ROOT and the bridge watches $NEW_WATCH"
fi

# --- the plan ------------------------------------------------------------------------------------
HIST_ACTION="unchanged"
if [ "$HIST_NEEDED" = 1 ] && [ "$HIST_PRESENT" = 0 ]; then HIST_ACTION="ADD 'hist: /cfg/hists' (the share is $FSTYPE; its sqlite files cannot be locked there)"; fi
MAP_OLD="" MAP_NEW=""
if [ "$KEEP_HISTORY" = 1 ] && [ "$OLD_WATCH_COUNT" = 1 ] && [ "$OLD_WATCH" != "$NEW_WATCH" ]; then MAP_OLD="$OLD_WATCH"; MAP_NEW="$NEW_WATCH"; fi

say "Plan ($( [ "$APPLY" = 1 ] && echo APPLYING || echo "dry run: nothing is changed" ))"
printf '  %-34s %s  ->  %s\n' "Folder copyparty serves (host):" "$OLD_DATA" "$DATA"
printf '  %-34s %s  ->  %s\n' "Copyparty web root (container):" "${OLD_ROOT:-/w (default)}" "$NEW_ROOT"
printf '  %-34s %s  ->  %s\n' "Bridge watches (container):" "${OLD_WATCH:-?}" "$NEW_WATCH"
printf '  %-34s %s\n' "Phone app upload path:" "$UPLOAD_PATH"
printf '  %-34s %s\n' "Index database (hist):" "$HIST_ACTION"
if [ -n "$MAP_OLD" ]; then
  printf '  %-34s %s -> %s (so nothing is re-hashed)\n' "Bridge import records:" "$MAP_OLD" "$MAP_NEW"
else
  printf '  %-34s %s\n' "Bridge import records:" "left alone (every file is re-checked once; nothing re-uploads, Immich recognises them)"
fi
echo "  Never touched: the files in $DATA, anything in Immich."

if [ "$APPLY" != 1 ]; then
  echo
  echo "Nothing was changed. Run again with --apply to do this."
  return 0
fi

# --- apply ---------------------------------------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="$COPYPARTY_DIR/backups/move-root-$TS"
mkdir -p "$BACKUP"
cp -p "$COMPOSE" "$BACKUP/compose.bak"
[ -n "$CONF" ] && cp -p "$CONF" "$BACKUP/conf.bak"
[ -f "$OVERRIDE" ] && cp -p "$OVERRIDE" "$BACKUP/override.bak"
[ -f "$ENVFILE" ] && cp -p "$ENVFILE" "$BACKUP/immich-bridge.env.bak"
[ -f "$HOOKENV" ] && cp -p "$HOOKENV" "$BACKUP/immich-bridge-hook.env.bak"
say "Backed up everything I will edit to $BACKUP"

say "Editing the compose file"
TMP="$(mktemp)"; CNT="$(mktemp)"
awk -v old="$OLD_DATA" -v new="$DATA" -v dest="$DEST" -v cnt="$CNT" '
  { line=$0; probe=line
    if (match(probe, /^[[:space:]]*-[[:space:]]*["\047]?/)) {
      pre=substr(probe, 1, RLENGTH); rest=substr(probe, RLENGTH+1)
      key=old ":" dest
      if (index(rest, key)==1) {
        nxt=substr(rest, length(key)+1, 1)
        if (nxt=="" || nxt==":" || nxt==" " || nxt=="\"" || nxt=="\047" || nxt=="#") {
          line=pre new ":" dest substr(rest, length(key)+1); n++
        }
      }
    }
    print line }
  END { print n+0 > cnt }' "$COMPOSE" > "$TMP"
[ "$(cat "$CNT")" = "1" ] || { rm -f "$TMP" "$CNT"; die "expected exactly one '$OLD_DATA:$DEST' line in $COMPOSE but found $(cat "$CNT" 2>/dev/null || echo 0); nothing was changed, edit it by hand"; }
cat "$TMP" > "$COMPOSE"; rm -f "$TMP" "$CNT"
echo "  $OLD_DATA -> $DATA"

if [ -n "$CONF" ]; then
  say "Editing copyparty's config ($CONF)"
  TMP="$(mktemp)"
  awk -v root="$NEW_ROOT" -v hist="$( [ "$HIST_NEEDED" = 1 ] && [ "$HIST_PRESENT" = 0 ] && echo 1 || echo 0 )" '
    /^\[global\][[:space:]]*(#.*)?$/ { print; if (hist=="1") print "  hist: /cfg/hists  # keep the index database on the VM disk (this share cannot lock sqlite files)"; next }
    /^\[\/\][[:space:]]*(#.*)?$/ { s=1; print; next }
    /^\[/ { s=0 }
    s && !done && !/^[[:space:]]*(#|$)/ { print "  " root "   # share this folder as the web root"; done=1; next }
    { print }' "$CONF" > "$TMP"
  cat "$TMP" > "$CONF"; rm -f "$TMP"
  echo "  web root -> $NEW_ROOT"
  if [ "$HIST_NEEDED" = 1 ] && [ "$HIST_PRESENT" = 0 ]; then
    mkdir -p "$CFG_SRC/hists"
    echo "  index database moved to the VM disk ($CFG_SRC/hists)"
  fi
fi

if [ -n "$MAP_OLD" ]; then
  say "Re-pointing the bridge's import records ($MAP_OLD -> $MAP_NEW)"
  IMG="$(docker inspect -f '{{.Config.Image}}' "$BRIDGE" 2>/dev/null || true)"
  if [ -n "$IMG" ]; then
    docker stop "$BRIDGE" >/dev/null 2>&1 || true
    touch "$BACKUP/state-restore.txt"
    docker run --rm -i --volumes-from "$BRIDGE" --entrypoint python "$IMG" - "$MAP_OLD" "$MAP_NEW" <<'PY' || echo "  (could not update the records; the bridge will simply re-check each file once)"
import os, shutil, sqlite3, sys
old, new = sys.argv[1], sys.argv[2]
db = "/data/state.db"
if not os.path.exists(db):
    print("  no import records yet"); sys.exit(0)
shutil.copy(db, db + ".pre-move")
con = sqlite3.connect(db)
pre = old.rstrip("/") + "/"
n = con.execute("SELECT COUNT(*) FROM files WHERE substr(path,1,?)=?", (len(pre), pre)).fetchone()[0]
con.execute("UPDATE OR IGNORE files SET path=? || substr(path,?) WHERE substr(path,1,?)=?",
            (new.rstrip("/") + "/", len(pre) + 1, len(pre), pre))
con.commit()
print("  %d file record(s) re-pointed (a copy of the old records is kept as state.db.pre-move)" % n)
PY
  else
    echo "  bridge container not found: skipped"
  fi
fi

say "Recreating copyparty with the new folder"
dc up -d --force-recreate "$CONTAINER"

if [ -d "$SRC_DIR/copyparty-immich-bridge" ] && [ -f "$SRC_DIR/copyparty-immich-bridge/install.sh" ]; then
  say "Re-running the bridge installer so the bridge follows (it keeps your key, token and settings)"
  APP_FOLDER="$APP_FOLDER" bash "$SRC_DIR/copyparty-immich-bridge/install.sh"
else
  echo "NOTE: $SRC_DIR has no installer; re-run the install one-liner with APP_FOLDER=$APP_FOLDER in front."
fi

# A folder list saved from the settings page wins over the installer's, so repoint it too.
TOKEN="$(sed -n 's/^BRIDGE_TOKEN=//p' "$ENVFILE" 2>/dev/null | head -n1 || true)"
if [ -n "$TOKEN" ]; then
  say "Updating the folders saved on the bridge's settings page"
  if curl -fsS -m 10 -X PUT -H "X-Bridge-Token: $TOKEN" -H 'Content-Type: application/json' \
       -d "{\"watch_dirs\":[\"$NEW_WATCH\"],\"priority_dirs\":[\"$NEW_WATCH\"]}" \
       "http://127.0.0.1:$BRIDGE_PORT/api/config" >/dev/null 2>&1; then
    echo "  watch + priority folder -> $NEW_WATCH"
  else
    echo "  could not update them; open the settings page > Folders & settings and check the folder there"
  fi
fi

# --- verify --------------------------------------------------------------------------------------
say "Checking the result"
problems=0
SINCE="$(docker inspect -f '{{.State.StartedAt}}' "$CONTAINER" 2>/dev/null || true)"
if docker exec "$CONTAINER" ls "$DEST" >/dev/null 2>&1; then
  echo "  copyparty sees $DEST: $(docker exec "$CONTAINER" ls "$DEST" 2>/dev/null | head -n 6 | tr '\n' ' ')"
else
  echo "  PROBLEM: copyparty cannot list $DEST"; problems=1
fi
sleep 5
LOGS="$(docker logs ${SINCE:+--since "$SINCE"} "$CONTAINER" 2>&1 || true)"
if printf '%s' "$LOGS" | grep -qiE 'cannot use database|database is locked'; then
  echo "  PROBLEM: copyparty cannot use its index database (a locking error in its log)."
  [ "$HIST_NEEDED" = 1 ] || echo "           If $DATA is on a network share, re-run with the share's type detected, or add 'hist: /cfg/hists' under [global]."
  problems=1
else
  echo "  copyparty log: no database errors so far"
fi
if curl -fsS -m 5 "http://127.0.0.1:$BRIDGE_PORT/healthz" >/dev/null 2>&1; then echo "  bridge: healthy"; else echo "  PROBLEM: the bridge is not answering on port $BRIDGE_PORT"; problems=1; fi

say "Done"
echo "Phone app: set the copyparty upload path to  $UPLOAD_PATH"
echo "Copyparty re-indexes the new folder first; uploads pause until that finishes ('uploads temporarily blocked due to indexing' in its log)."
echo "Undo everything:  bash move-root.sh --rollback $BACKUP --apply"
[ "$problems" = 0 ] || { echo; echo "Something above says PROBLEM: send me that output."; return 1; }
}

main "$@"
