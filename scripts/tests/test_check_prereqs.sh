#!/usr/bin/env bash
# shellcheck disable=SC2034  # rc is read by check() through eval
# Tests for the Railway CLI version check in check_prereqs.sh.
#
# Runs check_prereqs.sh for real with a stand-in `railway` (and `terraform`) on a PATH that holds only
# those stand-ins plus /usr/bin:/bin, so no real Railway, AWS, docker or Postgres tool is touched.
# --no-aws --no-vercel keeps the run offline apart from the stand-in `railway whoami`.
#
#   bash scripts/tests/test_check_prereqs.sh            # uses `bash` from PATH
#   BASH_UNDER_TEST=/bin/bash bash scripts/tests/...   # e.g. macOS bash 3.2
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
SH="$(command -v "${BASH_UNDER_TEST:-bash}")"

T="$(mktemp -d)"
trap '[ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"' EXIT
PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
# Inside checks, pipe into `grep >/dev/null`, not `grep -q`: -q exits early and, with pipefail,
# the writer's SIGPIPE turns a match into a random failure.
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# ---------------------------------------------------------------- stand-in CLIs
mkdir -p "$T/bin"
cat >"$T/bin/railway" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE_RAILWAY_LOG"
case "${1:-}" in
  --version)
    [ -n "${FAKE_RAILWAY_VERSION_FAILS:-}" ] && exit 1
    printf '%s\n' "$FAKE_RAILWAY_VERSION" ;;
  whoami) echo "Logged in as Test" ;;
  *) echo "fake railway: unhandled: $*" >&2; exit 64 ;;
esac
EOF
cat >"$T/bin/terraform" <<'EOF'
#!/bin/sh
case "$*" in
  "version -json") echo '{"terraform_version":"1.11.0"}' ;;
  *) echo "Terraform v1.11.0" ;;
esac
EOF
chmod +x "$T/bin/railway" "$T/bin/terraform"
export FAKE_RAILWAY_LOG="$T/railway.log"
TEST_PATH="$T/bin:/usr/bin:/bin"

# run <version string> [extra args...] -> out.txt, rc
run() {
  local ver="$1"
  shift
  rm -f "$FAKE_RAILWAY_LOG"
  rc=0
  FAKE_RAILWAY_VERSION="$ver" PATH="$TEST_PATH" "$SH" "$SCRIPTS/check_prereqs.sh" --no-aws --no-vercel "$@" \
    >"$T/out.txt" 2>&1 || rc=$?
}
version_row() { grep '^WARN   railway version' "$T/out.txt" || true; }

cd "$T"
echo "== check_prereqs.sh: Railway CLI version"

run "railway 4.16.1"
check "old 4.x: exit 0 (warning, not failure)" '[ "$rc" -eq 0 ]'
check "old 4.x: WARN row for the version" 'version_row | grep >/dev/null "4.16.1"'
check "old 4.x: names --tunnel-only and 5.27.0" 'version_row | grep >/dev/null "connect --tunnel-only.*5.27.0"'
check "old 4.x: names tcp-proxy and 5.15.0" 'version_row | grep >/dev/null "tcp-proxy.*5.15.0"'
check "old 4.x: names the inventory subcommands" 'version_row | grep >/dev/null "railway_inventory.sh"'
check "old 4.x: names the upgrade command" 'version_row | grep >/dev/null "brew upgrade railway"'
check "old 4.x: login row still reported" 'grep >/dev/null "^PASS   railway CLI .*v4.16.1, logged in" out.txt'
check "old 4.x: no FAIL row from railway" '! grep >/dev/null "^FAIL   railway" out.txt'

run "railway 5.20.3"
check "5.20.3: WARN names --tunnel-only" 'version_row | grep >/dev/null "connect --tunnel-only"'
check "5.20.3: tcp-proxy not listed (>= 5.15.0)" '! version_row | grep >/dev/null "tcp-proxy"'
check "5.20.3: 4.x subcommands not listed" '! version_row | grep >/dev/null "railway_inventory.sh"'

run "railway 5.27.0"
check "5.27.0 (minimum): no version WARN" '[ -z "$(version_row)" ]'
check "5.27.0: PASS row" 'grep >/dev/null "^PASS   railway CLI .*v5.27.0, logged in" out.txt'

run "railway 5.71.0"
check "5.71.0: no version WARN" '[ -z "$(version_row)" ]'
check "5.71.0: exit 0" '[ "$rc" -eq 0 ]'

run "railway 10.0.0"
check "10.0.0: compared numerically, no WARN" '[ -z "$(version_row)" ]'

run "railway dev|build <unknown>"
check "garbage: exit 0" '[ "$rc" -eq 0 ]'
check "garbage: WARN with the raw string" 'version_row | grep >/dev/null "unrecognized.*railway devbuild <unknown>"'
check "garbage: table separator stripped from raw string" '! grep >/dev/null "dev|build" out.txt'

run "railway 99999999999999999999.0.0"
check "oversized number: exit 0" '[ "$rc" -eq 0 ]'
check "oversized number: WARN, unrecognized" 'version_row | grep >/dev/null "unrecognized"'
check "oversized number: no shell error" '! grep >/dev/null "integer expression" out.txt'

run "railway 5.27.0-beta.1"
check "suffixed 5.27.0-beta.1: parsed, no WARN" '[ -z "$(version_row)" ]'

run ""
check "empty output: exit 0" '[ "$rc" -eq 0 ]'
check "empty output: WARN, unrecognized" 'version_row | grep >/dev/null "unrecognized"'

rm -f "$FAKE_RAILWAY_LOG"
rc=0
FAKE_RAILWAY_VERSION_FAILS=1 FAKE_RAILWAY_VERSION="railway 5.71.0" PATH="$TEST_PATH" \
  "$SH" "$SCRIPTS/check_prereqs.sh" --no-aws --no-vercel >"$T/out.txt" 2>&1 || rc=$?
check "--version exits non-zero: no crash, exit 0" '[ "$rc" -eq 0 ]'
check "--version exits non-zero: WARN, unrecognized" 'version_row | grep >/dev/null "unrecognized"'

run "railway 4.16.1" --no-railway
check "--no-railway: no railway rows" '! grep >/dev/null "railway" out.txt'
check "--no-railway: railway never called" '[ ! -e "$FAKE_RAILWAY_LOG" ]'

run "railway 4.16.1" --offline
check "--offline: no railway rows" '! grep >/dev/null "railway" out.txt'
check "--offline: railway never called" '[ ! -e "$FAKE_RAILWAY_LOG" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
