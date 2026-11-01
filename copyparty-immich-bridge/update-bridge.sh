#!/usr/bin/env bash
# update-bridge.sh: brings the Immich bridge up to the latest version. Saved in your copyparty folder by the installer.
#
#   ~/copyparty/update-bridge.sh            # update now (keeps your Immich key, web-page token, folders and settings)
#   ~/copyparty/update-bridge.sh --check    # only say whether a newer version exists; changes nothing
#
# It first makes sure THIS script is the latest published one (and swaps itself for the new one if not), then runs the
# latest installer, which fetches the newest bridge source, rebuilds the container and restarts it. It never touches
# your photos, copyparty's files or Immich.
# Set UPDATE_BRIDGE_NO_UPDATE=1 to skip the check for a newer update-bridge.sh.
set -euo pipefail

BRANCH="${BRANCH:-feature/copyparty-up2k-import}"
REPO="${REPO:-https://github.com/frostymccool/immich.git}"
RAW="${UPDATE_BRIDGE_RAW:-https://raw.githubusercontent.com/frostymccool/immich/$BRANCH/copyparty-immich-bridge}"
SELF_URL="$RAW/update-bridge.sh"
INSTALL_URL="$RAW/install.sh"

# Replaces this saved copy with the latest published update-bridge.sh and re-runs it, if they differ. Any problem
# (offline, an error page, a broken download) just carries on with this copy.
self_update() {
  [ "${UPDATE_BRIDGE_NO_UPDATE:-0}" = 1 ] && return 0
  [ "${UPDATE_BRIDGE_UPDATED:-0}" = 1 ] && return 0
  local self="${BASH_SOURCE[0]:-}"
  [ -n "$self" ] && [ -f "$self" ] || return 0   # piped from curl: this IS the latest
  command -v curl >/dev/null 2>&1 || { echo "(curl is missing: cannot check for a newer update-bridge.sh)"; return 0; }
  local tmp; tmp="$(mktemp)"
  if ! curl -fsSL -m 15 -o "$tmp" "$SELF_URL" 2>/dev/null || [ ! -s "$tmp" ]; then
    echo "(could not check for a newer update-bridge.sh; using this copy)"; rm -f "$tmp"; return 0
  fi
  if ! head -n1 "$tmp" | grep -q '^#!/usr/bin/env bash' || ! grep -q 'update-bridge.sh' "$tmp" || ! bash -n "$tmp" 2>/dev/null; then
    echo "(the downloaded update-bridge.sh looks wrong; using this copy)"; rm -f "$tmp"; return 0
  fi
  if cmp -s "$tmp" "$self"; then rm -f "$tmp"; return 0; fi
  echo "Updating update-bridge.sh to the latest version..."
  # write a new file and move it over the old one, so this running copy is never edited while bash reads it
  if cp "$tmp" "$self.new" 2>/dev/null && chmod --reference="$self" "$self.new" 2>/dev/null && mv "$self.new" "$self" 2>/dev/null; then
    rm -f "$tmp"
    UPDATE_BRIDGE_UPDATED=1 exec bash "$self" "$@"
  fi
  rm -f "$self.new"
  echo "(could not save the update next to this file; running the latest from a temporary copy)"
  UPDATE_BRIDGE_UPDATED=1 exec bash "$tmp" "$@"
}

# "abc1234 2026-11-01" of the running bridge container, or nothing
installed_build() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' immich-bridge 2>/dev/null | sed -n 's/^BRIDGE_BUILD=//p' | head -n1 || true
}

main() {
  self_update "$@"
  local check=0
  case "${1:-}" in
    --check) check=1 ;;
    "") ;;
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed 's/^# \{0,1\}//'; return 0 ;;
    *) echo "unknown option: $1 (try --check)" >&2; return 2 ;;
  esac

  local here="" before latest
  [ -n "${BASH_SOURCE[0]:-}" ] && here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
  if [ -z "${COPYPARTY_DIR:-}" ] && [ -n "$here" ] && { [ -f "$here/docker-compose.yml" ] || [ -f "$here/docker-compose.yaml" ] || [ -f "$here/compose.yml" ] || [ -f "$here/compose.yaml" ]; }; then
    export COPYPARTY_DIR="$here"
  fi

  before="$(installed_build)"
  echo "Installed now:   ${before:-unknown (the container is not running, or it predates build numbers)}"
  latest="$(git ls-remote "$REPO" "refs/heads/$BRANCH" 2>/dev/null | cut -c1-7 || true)"
  echo "Latest on GitHub: ${latest:-could not check}"
  if [ -n "$latest" ] && [ "${before%% *}" = "$latest" ]; then
    echo "Already on the latest version."
    [ "$check" = 1 ] && return 0
    echo "(running the installer anyway to make sure everything is in place)"
  elif [ "$check" = 1 ]; then
    [ -n "$latest" ] && echo "A newer version is available. Run this script without --check to update."
    return 0
  fi

  echo
  echo "==> Running the latest installer"
  curl -fsSL -m 30 "$INSTALL_URL" | bash

  echo
  echo "Now running:     $(installed_build)"
}

main "$@"
