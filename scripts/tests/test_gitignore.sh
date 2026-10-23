#!/usr/bin/env bash
# shellcheck disable=SC2034  # out is read by check() through eval
# Tests for lib/gitignore.sh (gitignore_add_dir), used by pg_migrate.sh, railway_inventory.sh and
# breach_check.sh to keep their output directories out of git. Needs git; no network, no docker.
#
#   bash scripts/tests/test_gitignore.sh               # uses `bash` from PATH
#   BASH_UNDER_TEST=/bin/bash bash scripts/tests/...   # e.g. macOS bash 3.2
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
SH="${BASH_UNDER_TEST:-bash}"

command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

T="$(mktemp -d)"
trap '[ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"' EXIT
PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
# Inside checks, pipe into `grep >/dev/null`, not `grep -q`: -q exits early and, with pipefail,
# the writer's SIGPIPE turns a match into a random failure.
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# add <cwd> <dir>: run gitignore_add_dir <dir> from <cwd> under the shell being tested
add() { (cd "$1" && "$SH" -c '. "$1"; gitignore_add_dir "$2"' _ "$SCRIPTS/lib/gitignore.sh" "$2" 2>&1); }

mkdir -p "$T/repo/migration/db" "$T/repo/sub" "$T/plain/out" "$T/elsewhere"
(cd "$T/repo" && git init -q .)

echo "== inside a git repository"
out="$(add "$T/repo/sub" ../migration/db)"
check "adds the directory relative to the repository root" '[ "$(cat "$T/repo/.gitignore")" = "migration/db/" ]'
check "says what it added" 'printf "%s\n" "$out" | grep "added" | grep >/dev/null "migration/db/"'
out="$(add "$T/repo" migration/db)"
check "a second call adds nothing" '[ "$(grep -cxF "migration/db/" "$T/repo/.gitignore")" = "1" ] && [ -z "$out" ]'
check "git no longer lists files in it" \
  'touch "$T/repo/migration/db/dump.txt" && [ -z "$(cd "$T/repo" && git status --porcelain --untracked-files=all | grep "dump.txt")" ]'

echo "== the repository root itself"
before="$(cat "$T/repo/.gitignore")"
out="$(add "$T/repo" .)"
check "the repository root is not added (would write an absolute path that ignores nothing)" \
  '[ "$(cat "$T/repo/.gitignore")" = "$before" ]'
check "it says why" 'printf "%s\n" "$out" | grep >/dev/null "repository root"'
out="$(add "$T/repo/sub" ..)"
check "also when given as a relative path from a subdirectory" '[ "$(cat "$T/repo/.gitignore")" = "$before" ]'

echo "== outside a git repository"
out="$(add "$T/plain" out)"
check "falls back to the current directory" '[ "$(cat "$T/plain/.gitignore")" = "out/" ]'
out="$(add "$T/plain" "$T/elsewhere")"
check "a directory outside the root is left to the user" \
  'printf "%s\n" "$out" | grep >/dev/null "add it to your ignore rules yourself" && [ "$(cat "$T/plain/.gitignore")" = "out/" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
