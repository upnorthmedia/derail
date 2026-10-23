#!/usr/bin/env bash
# shellcheck disable=SC2034  # rc and FIXTURE_VALUES are read by check() through eval
# Tests for breach_check.sh and the exposed-value guard in put_secrets.sh.
#
# Runs both scripts for real against a stand-in `railway` CLI on PATH (Railway itself can't be used
# in a test), then asserts on output, exit codes, file modes, and that no fixture value ever shows up
# in anything the scripts print or write. put_secrets.sh runs in --dry-run, so no AWS call is made.
#
#   bash scripts/tests/test_breach_tools.sh            # uses `bash` from PATH
#   BASH_UNDER_TEST=/bin/bash bash scripts/tests/...   # e.g. macOS bash 3.2
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
SH="${BASH_UNDER_TEST:-bash}"

T="$(mktemp -d)"
trap '[ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"' EXIT
PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
# Inside checks, pipe into `grep >/dev/null`, not `grep -q`: -q exits early and, with pipefail,
# the writer's SIGPIPE turns a match into a random failure.
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# ---------------------------------------------------------------- fake railway CLI
mkdir -p "$T/bin" "$T/fixture/vars"
cat >"$T/bin/railway" <<'EOF'
#!/usr/bin/env bash
set -eu
D="$FAKE_RAILWAY_DIR"
# 5.x-like `--help`: railway_inventory.sh reads the Commands: block to decide which subcommands exist.
if [ "${!#}" = "--help" ]; then
  words="$*"; words="${words%--help}"; words="${words% }"
  case "$words" in
    "") cmds="bucket config cron domain environment functions link list postgres service status usage variable volume whoami help" ;;
    service) cmds="list link status help" ;;
    environment) cmds="config list new help" ;;
    domain|volume|bucket|cron|functions) cmds="list help" ;;
    config) cmds="pull help" ;;
    postgres) cmds="ha pgbouncer pitr help" ;;
    "postgres ha"|"postgres pgbouncer"|"postgres pitr") cmds="status help" ;;
    usage) cmds="projects help" ;;
    *) echo "error: unrecognized subcommand '${words%% *}'" >&2; exit 2 ;;
  esac
  printf 'Usage: railway %s [COMMAND]\n\nCommands:\n' "$words"
  for c in $cmds; do printf '  %-12s %s\n' "$c" "$c"; done
  printf '\nOptions:\n  -h, --help  Print help\n'
  exit 0
fi
svc=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[$i]}" = "-s" ] && svc="${args[$((i + 1))]}"; done
case "${1:-} ${2:-}" in
  "whoami "*) echo "Logged in as Test" ;;
  "list --json") cat "$D/projects.json" ;;
  "link "*) : ;;
  "variable list")
    if [ -n "${FAKE_NO_VARIABLE_SUBCMD:-}" ]; then echo "error: unrecognized subcommand 'variable'" >&2; exit 2; fi
    if [ "$svc" = "${FAKE_FAIL_SERVICE:-}" ]; then echo "error: failed to fetch variables" >&2; exit 1; fi
    cat "$D/vars/$svc.json" ;;
  "variables "*)
    if [ "$svc" = "${FAKE_FAIL_SERVICE:-}" ]; then echo "error: failed to fetch variables" >&2; exit 1; fi
    cat "$D/vars/$svc.json" ;;
  "service list") echo '[{"name":"web"},{"name":"Postgres"}]' ;;
  *) echo "fake railway: unhandled: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$T/bin/railway"
export FAKE_RAILWAY_DIR="$T/fixture"
export PATH="$T/bin:$PATH"

cat >"$T/fixture/projects.json" <<'EOF'
[{"id":"p1","name":"shop","environments":{"edges":[{"node":{"id":"e1","name":"production","serviceInstances":{"edges":[{"node":{"serviceId":"s1"}},{"node":{"serviceId":"s2"}}]}}}]},
  "services":{"edges":[{"node":{"id":"s1","name":"web"}},{"node":{"id":"s2","name":"Postgres"}}]}}]
EOF
# Fixture values are assembled at runtime so no literal in this file looks like a credential to the
# CI secrets-scan grep or to gitleaks. They still start with the real prefixes.
FX_STRIPE="sk_live""_FIXTUREstripe000000001"
FX_WHSEC="whsec""_FIXTUREwebhook00000001"
FX_GHP="ghp""_FIXTUREgithub00000000000001"
FX_PGPASS="FIXTUREpgpass000000001"
write_web() {
  cat >"$T/fixture/vars/web.json" <<EOF
{"OPENAI_API_KEY":"$1","STRIPE_SECRET_KEY":"$FX_STRIPE","STRIPE_WEBHOOK_SECRET":"$FX_WHSEC",
 "BETTER_AUTH_SECRET":"FIXTUREauthsecret0000000000000001","GITHUB_TOKEN":"$FX_GHP",
 "DATABASE_URL":"\${{Postgres.DATABASE_URL}}","LOG_LEVEL":"info","NEXT_PUBLIC_SITE_URL":"https://shop.example",
 "RAILWAY_PUBLIC_DOMAIN":"web-production.up.railway.app","POSTMARK_SERVER_TOKEN":"$2",
 "AWS_REGION":"us-east-1","S3_BUCKET":"shop-uploads-prod","BETTER_AUTH_URL":"https://shop.example",
 "GITHUB_CLIENT_ID":"Iv1.0123456789abcdef","GITHUB_CLIENT_SECRET":"FIXTUREghoauth000000000001","SLACK_WEBHOOK_URL":"https://hooks.slack.com/services/FIXTUREslackhook0001"}
EOF
}
write_web "sk-proj-FIXTUREopenai0000000000001" "FIXTUREpostmark00000000000001"
cat >"$T/fixture/vars/Postgres.json" <<EOF
{"DATABASE_URL":"postgresql://postgres:$FX_PGPASS@postgres.railway.internal:5432/railway",
 "DATABASE_PUBLIC_URL":"postgresql://postgres:$FX_PGPASS@proxy.rlwy.net:12345/railway",
 "PGPASSWORD":"$FX_PGPASS","PGPORT":"5432","PGUSER":"postgres"}
EOF
FIXTURE_VALUES="FIXTURE|sk-proj-|sk_live_|whsec_|ghp_|$FX_STRIPE|$FX_WHSEC|$FX_GHP|$FX_PGPASS"

cd "$T"
echo "== breach_check.sh"

check "fixtures carry the real key prefixes" '[ "$(jq -r .STRIPE_SECRET_KEY "$T/fixture/vars/web.json")" = "$FX_STRIPE" ] && [ "${FX_STRIPE#sk_live_}" != "$FX_STRIPE" ] && [ "${FX_WHSEC#whsec_}" != "$FX_WHSEC" ] && [ "${FX_GHP#ghp_}" != "$FX_GHP" ] && [ "$(jq -r .PGPASSWORD "$T/fixture/vars/Postgres.json")" = "$FX_PGPASS" ]'
rc=0; "$SH" "$SCRIPTS/breach_check.sh" --out exposure.md --fingerprint secrets/railway.burned.sha256 >stdout.txt 2>stderr.txt || rc=$?
check "exits 0" '[ "$rc" -eq 0 ]'
check "AI key is in group 1" 'awk "/^## 1\\./,/^## 2\\./" exposure.md | grep >/dev/null "OPENAI_API_KEY"'
check "database vars are in group 3" 'awk "/^## 3\\./,/^## 4\\./" exposure.md | grep >/dev/null "PGPASSWORD"'
check "Stripe webhook secret groups with payments" 'awk "/^## 4\\./,/^## 5\\./" exposure.md | grep >/dev/null "STRIPE_WEBHOOK_SECRET"'
check "GitHub token is a deploy token" 'awk "/^## 5\\./,/^## 6\\./" exposure.md | grep >/dev/null "GITHUB_TOKEN"'
check "GitHub OAuth client secret is not a deploy token" '! awk "/^## 5\\./,/^## 6\\./" exposure.md | grep >/dev/null "GITHUB_CLIENT_SECRET" && grep >/dev/null "GITHUB_CLIENT_SECRET" exposure.md'
check "auth secret is a session secret" 'awk "/^## 6\\./,/^## 8\\./" exposure.md | grep >/dev/null "BETTER_AUTH_SECRET"'
check "reference var points at its source" 'awk "/^## 9\\./,/^## Not covered/" exposure.md | grep >/dev/null "DATABASE_URL\` (shop/production/web)"'
check "short config value is left out" '! grep -q "LOG_LEVEL" exposure.md'
check "short database config (port) is left out" '! grep -q "PGPORT" exposure.md'
check "well-known config names are left out" '! grep -Eq "AWS_REGION|S3_BUCKET|BETTER_AUTH_URL|GITHUB_CLIENT_ID|PGUSER" exposure.md'
check "config is not fingerprinted" '! grep -Eq "/(AWS_REGION|S3_BUCKET|BETTER_AUTH_URL|GITHUB_CLIENT_ID|PGUSER)$" secrets/railway.burned.sha256'
check "a webhook URL is still a secret" 'grep -q "SLACK_WEBHOOK_URL" exposure.md'
check "public build-time var is left out" '! grep -q "NEXT_PUBLIC_SITE_URL" exposure.md'
check "Railway-injected var is left out" '! grep -q "RAILWAY_PUBLIC_DOMAIN" exposure.md'
check "fingerprint file is mode 600" '[ "$(stat -c %a secrets/railway.burned.sha256 2>/dev/null || stat -f %Lp secrets/railway.burned.sha256)" = "600" ]'
check "fingerprints cover exported values" '[ "$(wc -l <secrets/railway.burned.sha256 | tr -d " ")" -ge 8 ]'
check "no value in checklist, stdout, stderr or fingerprints" '! grep -Eq "$FIXTURE_VALUES" exposure.md stdout.txt stderr.txt secrets/railway.burned.sha256'

rc=0; "$SH" "$SCRIPTS/breach_check.sh" --out v1.md --verify secrets/railway.burned.sha256 >verify1.txt 2>&1 || rc=$?
check "verify before rotation exits 1" '[ "$rc" -eq 1 ]'
check "verify lists the unrotated AI key" 'grep -q "shop/production/web/OPENAI_API_KEY" v1.md'

write_web "sk-proj-FIXTUREopenaiROTATED00000002" "FIXTUREpostmark00000000000001"
"$SH" "$SCRIPTS/breach_check.sh" --out v2.md --verify secrets/railway.burned.sha256 >/dev/null 2>&1 || true
check "verify drops a rotated key" '! grep -q "web/OPENAI_API_KEY" v2.md && grep -q "web/POSTMARK_SERVER_TOKEN" v2.md'

mkdir -p nested/migration
rc=0; (cd nested && "$SH" "$SCRIPTS/breach_check.sh" --out migration/BREACH-CHECK.md >../nested.out 2>&1) || rc=$?
check "--out in a subdirectory works (paths survive the cd into the link dir)" '[ "$rc" -eq 0 ] && grep -q "0 unreadable" nested.out && grep -q "OPENAI_API_KEY" nested/migration/BREACH-CHECK.md'

if command -v git >/dev/null 2>&1; then
  mkdir -p repo && (cd repo && git init -q . && "$SH" "$SCRIPTS/breach_check.sh" --out migration/BREACH-CHECK.md \
    --fingerprint migration/.secrets/railway.burned.sha256 >/dev/null 2>&1) || true
  check "fingerprint dir is added to the repo's .gitignore" 'grep -qxF "migration/.secrets/" repo/.gitignore'
  check "git does not see the fingerprint file" '[ -z "$(cd repo && git status --porcelain --untracked-files=all | grep "railway.burned")" ]'
else
  echo "  skip  .gitignore checks (git not installed)"
fi

FAKE_NO_VARIABLE_SUBCMD=1 "$SH" "$SCRIPTS/breach_check.sh" --out fallback.md >/dev/null 2>&1 || true
check "falls back to \`railway variables\` on older CLIs" 'grep -q "OPENAI_API_KEY" fallback.md'

# Re-running --fingerprint after rotation started would replace the record of the exposed values.
cp secrets/railway.burned.sha256 burned.before
rc=0; "$SH" "$SCRIPTS/breach_check.sh" --out again.md --fingerprint secrets/railway.burned.sha256 >again.txt 2>&1 || rc=$?
check "--fingerprint refuses to overwrite an existing fingerprint file (exit 2)" '[ "$rc" -eq 2 ] && grep >/dev/null "already exists" again.txt'
check "the existing fingerprint file is unchanged" 'cmp -s burned.before secrets/railway.burned.sha256'

# --verify must not pass the gate when a service could not be read.
printf '%s\t%s\n' "0000000000000000000000000000000000000000000000000000000000000000" "nowhere/NONE" >none.sha256
rc=0; "$SH" "$SCRIPTS/breach_check.sh" --out vok.md --verify none.sha256 >vok.txt 2>&1 || rc=$?
check "--verify with nothing exposed and every service read exits 0" '[ "$rc" -eq 0 ]'
rc=0; FAKE_FAIL_SERVICE=Postgres "$SH" "$SCRIPTS/breach_check.sh" --out vfail.md --verify none.sha256 >vfail.txt 2>&1 || rc=$?
check "--verify exits 3 when a service could not be read and nothing else is exposed" '[ "$rc" -eq 3 ]'
check "it says the result is incomplete" 'grep >/dev/null "could not be read" vfail.txt'
rc=0; FAKE_FAIL_SERVICE=Postgres "$SH" "$SCRIPTS/breach_check.sh" --out vboth.md --verify secrets/railway.burned.sha256 >/dev/null 2>&1 || rc=$?
check "an exposed value still exits 1 when a service also failed" '[ "$rc" -eq 1 ]'

# The secrets directory is private from the moment it is created.
rc=0; (umask 022; "$SH" "$SCRIPTS/breach_check.sh" --out fresh.md --fingerprint fresh/.secrets/railway.burned.sha256 >/dev/null 2>&1) || rc=$?
check "a new --fingerprint directory is created mode 700" '[ "$rc" -eq 0 ] && [ "$(stat -c %a fresh/.secrets 2>/dev/null || stat -f %Lp fresh/.secrets)" = "700" ]'

echo "== railway_inventory.sh (shared classifier)"
mkdir -p inv && (cd inv && "$SH" "$SCRIPTS/railway_inventory.sh" --project p1 >inv.out 2>&1) || true
check "classifies with the shared classifier" '[ "$(jq -r ".variables[] | select(.name==\"OPENAI_API_KEY\") | .class" inv/migration/inventory/railway/variables/web.json)" = "app_secret" ]'
check "references stay references" '[ "$(jq -r ".variables[] | select(.name==\"DATABASE_URL\") | .class" inv/migration/inventory/railway/variables/web.json)" = "reference" ]'
check "values land only in .secrets" '[ -s inv/migration/.secrets/railway.web.env ] && ! grep -Eqr "$FIXTURE_VALUES" inv/migration/inventory inv/inv.out'
check "runs with its subcommand guard active" '[ -f inv/migration/inventory/railway/errors.log ] && ! grep "subcommand checks\] disabled" inv/migration/inventory/railway/errors.log >/dev/null'

echo "== put_secrets.sh exposed-value guard (dry-run)"
mkdir -p mig
cp secrets/railway.burned.sha256 mig/railway.burned.sha256
put() { "$SH" "$SCRIPTS/put_secrets.sh" --secret-name shop-prod/app --dry-run "$@"; }

printf 'OPENAI_API_KEY=sk-proj-FIXTUREopenai0000000000001\nSESSION_SECRET=FIXTUREfreshvalue00000000000009\n' >mig/aws.prod.env
rc=0; put --env-file mig/aws.prod.env >p1.out 2>p1.err || rc=$?
check "refuses an exposed value (auto-detected fingerprint file)" '[ "$rc" -eq 2 ] && grep -q "OPENAI_API_KEY" p1.err'
check "names the key but never the value" '! grep -Eq "$FIXTURE_VALUES" p1.out p1.err'

rc=0; put --env-file mig/aws.prod.env --allow-carryover OPENAI_API_KEY >p2.out 2>&1 || rc=$?
check "--allow-carryover accepts it" '[ "$rc" -eq 0 ] && grep -q "carried over on purpose: OPENAI_API_KEY" p2.out'

printf 'OPENAI_API_KEY=sk-proj-FIXTUREopenaiROTATED00000002\n' >mig/aws.prod.env
rc=0; put --env-file mig/aws.prod.env >p3.out 2>&1 || rc=$?
check "accepts a rotated value" '[ "$rc" -eq 0 ] && grep -q "exposed-value check: passed" p3.out'

mkdir -p calm
printf 'OPENAI_API_KEY=sk-proj-FIXTUREopenai0000000000001\n' >calm/aws.prod.env
rc=0; put --env-file calm/aws.prod.env >p4.out 2>&1 || rc=$?
check "no fingerprint file: ordinary migration is unaffected" '[ "$rc" -eq 0 ] && ! grep -q "exposed-value check" p4.out'

printf 'S3_BUCKET=shop-uploads-prod\nAPP_ORIGIN=https://shop.example\n' >mig/config.env
rc=0; put --env-file mig/config.env >p6.out 2>&1 || rc=$?
check "config values that also lived on Railway pass the guard" '[ "$rc" -eq 0 ] && grep -q "exposed-value check: passed" p6.out'

rc=0; put --env-file calm/aws.prod.env --burned-hashes mig/railway.burned.sha256 >p5.out 2>&1 || rc=$?
check "explicit --burned-hashes is enforced" '[ "$rc" -eq 2 ] && grep -q "match fingerprints of exposed" p5.out'

printf 'OPENAI_API_KEY=sk-proj-FIXTUREopenai0000000000001\n' >mig/aws.prod.env
if put --env-file mig/aws.prod.env --no-burned-check >/dev/null 2>&1; then ok "--no-burned-check skips it"; else bad "--no-burned-check skips it"; fi

echo
echo "passed: $PASS  failed: $FAIL  (shell: $("$SH" -c 'echo $BASH_VERSION'))"
[ "$FAIL" -eq 0 ]
