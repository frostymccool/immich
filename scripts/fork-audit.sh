#!/usr/bin/env bash
# Fork safety audit: fails (exit 1) if anything sensitive or personal is about to ship.
# Run it before every push (CLAUDE.md) and it runs automatically in every fork pipeline
# (.github/workflows/fork-audit.yml, build-custom-apk.yml, bridge-tests.yml).
#
#   scripts/fork-audit.sh            audit the git-tracked tree
#   scripts/fork-audit.sh --apk F    additionally inspect a built APK/AAB for packaged secrets
#
# What it checks
#   1. no secret-bearing files tracked (.env, keystores, keys, certs, databases, logs, APKs)
#   2. no high-confidence secrets anywhere in tracked text (private keys, cloud/GitHub/Slack tokens,
#      long key/password/token assignments)
#   3. in FORK-OWNED paths only: no private IPs, personal emails, home directories or real-looking
#      tokens - examples must use the generic values below
#   4. .gitignore still covers the files the installer / signing / local runs create
#   5. the tip commit's author is not a personal email (git config leaking into history)
#   6. (--apk) the built package does not contain keystores, keys, env files or properties
#
# Upstream Immich files that legitimately match (their own placeholders / test keys) are listed in
# ALLOW_FILES. Keep that list short and justified.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2

APK=""
if [ "${1:-}" = "--apk" ]; then APK="${2:-}"; fi

FAIL=0
fail() { printf '  FAIL  %s\n' "$*"; FAIL=1; }
ok() { printf '  ok    %s\n' "$*"; }
section() { printf '\n[%s]\n' "$*"; }

# Upstream-provided files that look sensitive but are public placeholders / test fixtures.
ALLOW_FILES=(
  ".vscode/settings.json"
  "mobile/.vscode/settings.json"
  "deployment/.env"            # upstream docker-compose sample (DB_PASSWORD=postgres placeholder)
  "docker/example.env"         # upstream sample
  "packages/e2e-auth-server/test-keys.ts"   # upstream e2e test key pair, not a real credential
)
allowed() { local f="$1" a; for a in "${ALLOW_FILES[@]}"; do [ "$f" = "$a" ] && return 0; done; return 1; }

# Paths this fork owns: the strict personal-data rules apply here.
OWN=(
  ':(glob)copyparty-immich-bridge/**'
  ':(glob)scripts/**'
  'CLAUDE.md'
  'IOS_BETA_HANDOFF.md'
  ':(glob).github/workflows/build-custom-apk.yml'
  ':(glob).github/workflows/bridge-tests.yml'
  ':(glob).github/workflows/fork-audit.yml'
  ':(glob)mobile/**/*copyparty*'
  ':(glob)mobile/**/*bridge*'
  ':(glob)mobile/bin/copyparty*'
  ':(glob)mobile/test/**/*copyparty*'
)
# Not scanned for personal data: this script itself (it names the patterns).
SELF=':(exclude)scripts/fork-audit.sh'

section "1. secret-bearing files tracked in git"
bad=0
while IFS= read -r f; do
  allowed "$f" && continue
  fail "tracked sensitive file: $f"; bad=1
done < <(git ls-files | grep -Ei '(^|/)(\.env|[^/]*\.env|key\.properties|[^/]*\.jks|[^/]*\.keystore|[^/]*\.p12|[^/]*\.pfx|[^/]*\.pem|[^/]*\.crt|id_rsa[^/]*|id_ed25519[^/]*|[^/]*\.sqlite3?|state\.db[^/]*|settings\.json|[^/]*\.log|[^/]*\.apk|[^/]*\.aab|google-services\.json|GoogleService-Info\.plist|[^/]*\.mobileprovision)$')
[ "$bad" = 0 ] && ok "none"

section "2. high-confidence secrets in tracked text"
hits="$(git grep -nIP '(BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{32,}|(?i:api[_-]?key|apikey|secret|passw(or)?d|bearer|token)["'"'"']?\s*[:=]\s*["'"'"']?(?=[A-Za-z0-9+/_-]*\d)[A-Za-z0-9+/_-]{24,}["'"'"']?(?![\w(]))' -- . ':!*.lock' ':!pnpm-lock.yaml' ':!i18n' ':!*.svg' ':!*.min.js' "$SELF" 2>/dev/null | grep -v 'EXAMPLE' || true)"
found=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  f="${line%%:*}"
  allowed "$f" && continue
  fail "$(printf '%s' "$line" | cut -c1-150)"; found=1
done <<< "$hits"
[ "$found" = 0 ] && ok "none"

section "3. personal data in fork-owned files"
scan() { # label, regex (PCRE), optional extra grep -v filter
  local label="$1" re="$2" skip="${3:-^$}" out
  out="$(git grep -nIP "$re" -- "${OWN[@]}" "$SELF" 2>/dev/null | grep -Ev "$skip" || true)"
  if [ -n "$out" ]; then
    while IFS= read -r l; do fail "$label: $(printf '%s' "$l" | cut -c1-140)"; done <<< "$out"
    return 1
  fi
  return 0
}
clean=1
# private IPv4 literals other than the documented generic example
scan "private IP (use 192.168.1.50)" '\b(10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b' '192\.168\.1\.50|192\.168\.1\.0|10\.0\.0\.0' || clean=0
# personal e-mail addresses (noreply / example addresses are fine)
scan "e-mail address" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' 'noreply@anthropic\.com|users\.noreply\.github\.com|@example\.|@docker-vm|git@github\.com|user@docker-vm' || clean=0
# real home directories (generic /home/user and CI /home/runner are fine)
scan "home directory (use /home/user)" '/home/(?!user\b|runner\b|\$|<|\{)[A-Za-z0-9_.-]+' || clean=0
# real-looking tokens in links
scan "real-looking token in a link" '#token=(?!EXAMPLE|…|<|\.\.\.|\$)[A-Za-z0-9_-]{12,}' || clean=0
# user@host shell prompts other than the generic one
scan "personal prompt (use user@docker-vm)" '\b(?!user@docker-vm)[a-z][a-z0-9_-]{1,15}@[a-z][a-z0-9-]{2,}:~\$' || clean=0
[ "$clean" = 1 ] && ok "none"

section "4. .gitignore still protects secrets and local state"
gi=0
for p in immich-bridge.env immich-bridge-hook.env docker-compose.override.yml mobile/android/key.properties \
         mobile/android/app/upload.jks mobile/android/key.jks x.keystore x.p12 x.pem \
         copyparty-immich-bridge/state.db copyparty-immich-bridge/settings.json copyparty-immich-bridge/x.log; do
  if ! git check-ignore -q "$p"; then fail "not ignored: $p"; gi=1; fi
done
[ "$gi" = 0 ] && ok "all ignored"

section "5. tip commit author"
ae="$(git log -1 --format=%ae 2>/dev/null)"; ce="$(git log -1 --format=%ce 2>/dev/null)"
parents="$(git rev-list --parents -n1 HEAD 2>/dev/null | wc -w)"
if [ "$ce" = "noreply@github.com" ] && [ "$parents" -ge 3 ]; then
  # GitHub's synthetic pull-request merge commit carries the PR opener's identity; the workflows
  # check out the real head commit instead, so there is nothing of ours to judge here.
  ae="noreply@github.com"; ce="noreply@github.com"
fi
for e in "$ae" "$ce"; do
  case "$e" in
    ""|*noreply*|*github-actions*|*@anthropic.com) ;;
    *) fail "tip commit uses a personal e-mail ($e); set git config user.email to a noreply address" ;;
  esac
done
[ "$FAIL" = 0 ] && ok "noreply author ($ae)"

if [ -n "$APK" ]; then
  section "6. built package contents ($APK)"
  if [ ! -f "$APK" ]; then fail "package not found: $APK"
  else
    listing="$(unzip -Z1 "$APK" 2>/dev/null || true)"
    pk=0
    while IFS= read -r e; do
      [ -z "$e" ] && continue
      case "$e" in
        *.jks|*.keystore|*.p12|*.pfx|*.pem|*key.properties|*.env|*immich-bridge*|*settings.json|*.sqlite|*.db-wal) fail "package contains $e"; pk=1 ;;
      esac
    done <<< "$listing"
    [ "$pk" = 0 ] && ok "no keystores, keys, env or state files inside"
  fi
fi

printf '\n'
if [ "$FAIL" = 0 ]; then echo "AUDIT PASSED"; else echo "AUDIT FAILED - nothing sensitive may be pushed or released"; fi
exit "$FAIL"
