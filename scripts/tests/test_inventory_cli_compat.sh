#!/usr/bin/env bash
# shellcheck disable=SC2034  # rc and FIXTURE_VALUES are read by check() through eval
# Tests that railway_inventory.sh exports variables on both Railway CLI generations:
#   new (5.x): `railway variable list -s <svc> -e <env> --json|--kv`
#   old (4.16.1 and earlier): no `variable` subcommand, only `railway variables ... --json|--kv`
#
# Runs the script for real against a stand-in `railway` CLI on PATH, then asserts on the variable
# export, errors.log, and that no fixture value shows up outside the secrets dir.
#
#   bash scripts/tests/test_inventory_cli_compat.sh            # uses `bash` from PATH
#   BASH_UNDER_TEST=/bin/bash bash scripts/tests/...           # e.g. macOS bash 3.2
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
# FAKE_CLI=old  behaves like 4.16.1: `variable` is an unknown subcommand (clap exit 2), `service list`
#               and friends do not exist, and `--help` lists the subcommands 4.16.1 lists.
# FAKE_CLI=new  behaves like 5.x: `variable list` works and every inventory subcommand exists.
# FAKE_JSON_BROKEN=1  makes every --json variable listing fail, so only --kv works.
# FAKE_KV_BROKEN=1    makes every --kv variable listing fail too.
# Every call (full argv) is appended to $FAKE_RAILWAY_DIR/calls.log.
mkdir -p "$T/bin" "$T/fixture/vars"
cat >"$T/bin/railway" <<'EOF'
#!/usr/bin/env bash
set -eu
D="$FAKE_RAILWAY_DIR"
echo "$*" >>"$D/calls.log"

# clap-style help. Subcommand lists are taken from `railway <cmd> --help` on 4.16.1 and 5.71.0
# (trimmed to what the inventory uses). 4.16.1 `domain` has no subcommands at all.
help_out() {
  local cmds c
  case "$FAKE_CLI:$1" in
    old:) cmds="add completion connect deploy deployment dev domain docs down environment init link list login logout logs open run service shell ssh status unlink up variables whoami volume redeploy scale functions help" ;;
    old:service) cmds="link status help" ;;
    old:environment) cmds="new delete help" ;;
    old:domain) cmds="" ;;
    old:volume) cmds="list add delete update detach attach help" ;;
    old:functions) cmds="list new delete push pull link help" ;;
    new:) cmds="add bucket config cron domain environment functions link list postgres service status usage variable volume whoami help" ;;
    new:service) cmds="list delete link status help" ;;
    new:environment) cmds="link new delete config list help" ;;
    new:domain) cmds="list status delete help" ;;
    new:volume) cmds="list add delete help" ;;
    new:bucket) cmds="list create delete help" ;;
    new:cron) cmds="list run help" ;;
    new:config) cmds="plan apply init pull help" ;;
    new:postgres) cmds="pitr ha pgbouncer history help" ;;
    "new:postgres ha"|"new:postgres pgbouncer"|"new:postgres pitr") cmds="status help" ;;
    new:usage) cmds="projects limit help" ;;
    new:functions) cmds="list new delete help" ;;
    *) printf "error: unrecognized subcommand '%s'\n" "${1%% *}" >&2; exit 2 ;;
  esac
  printf 'Does things\n\nUsage: railway %s [COMMAND]\n\n' "$1"
  if [ -n "$cmds" ]; then
    echo "Commands:"
    for c in $cmds; do printf '  %-12s Does %s\n' "$c" "$c"; done
    echo
  fi
  printf 'Options:\n  -h, --help     Print help\n'
}
if [ "${!#}" = "--help" ]; then
  words="$*"; words="${words%--help}"; words="${words% }"
  help_out "$words"; exit 0
fi

svc=""; fmt=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -s) svc="${args[$((i + 1))]}" ;;
    --json) fmt=json ;;
    --kv) fmt=kv ;;
  esac
done
list_vars() {
  if [ "$fmt" = json ] && [ -n "${FAKE_JSON_BROKEN:-}" ]; then echo "fake: json listing failed" >&2; exit 1; fi
  if [ "$fmt" = kv ] && [ -n "${FAKE_KV_BROKEN:-}" ]; then echo "fake: kv listing failed" >&2; exit 1; fi
  case "$fmt" in
    json) cat "$D/vars/$svc.json" ;;
    kv) jq -r 'to_entries[] | "\(.key)=\(.value)"' "$D/vars/$svc.json" ;;
    *) echo "fake: listing needs --json or --kv" >&2; exit 64 ;;
  esac
}
case "${1:-} ${2:-}" in
  "whoami "*) echo "Logged in as Test" ;;
  "link "*) : ;;
  "status --json") if [ "$FAKE_CLI" = new ]; then cat "$D/status-5.json"; else cat "$D/status.json"; fi ;;
  "service list")
    if [ "$FAKE_CLI" = old ]; then echo "fake 4.16.1: would link a service named 'list'" >&2; exit 1; fi
    cat "$D/service-list.json" ;;
  "service status")
    # legacy ServiceStatusOutput, same on 4.16.1 and 5.71.0 (src/commands/service.rs)
    if [ "$FAKE_CLI" = new ]; then echo "Warning: \`railway service status --all\` is deprecated. Please use \`railway service list\` instead." >&2; fi
    echo '[{"id":"s1","name":"web","deploymentId":null,"status":null,"stopped":false}]' ;;
  "variable list")
    if [ "$FAKE_CLI" = old ]; then
      printf "error: unrecognized subcommand 'variable'\n\n  tip: a similar subcommand exists: 'variables'\n" >&2; exit 2
    fi
    list_vars ;;
  "variable "*)
    printf "error: unrecognized subcommand 'variable'\n" >&2; exit 2 ;;
  "variables "*) list_vars ;;
  *) echo "fake railway: unhandled: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$T/bin/railway"
export FAKE_RAILWAY_DIR="$T/fixture"
export PATH="$T/bin:$PATH"

cat >"$T/fixture/vars/web.json" <<'EOF'
{"OPENAI_API_KEY":"sk-proj-FIXTUREopenai0000000000001","DATABASE_URL":"${{Postgres.DATABASE_URL}}",
 "LOG_LEVEL":"info","RAILWAY_PUBLIC_DOMAIN":"web-production.up.railway.app"}
EOF
FIXTURE_VALUES="FIXTURE|sk-proj-"

# `railway status --json` prints the `Project` GraphQL result as JSON (railwayapp/cli v4.16.1:
# src/commands/status.rs, src/gql/queries/strings/Project.graphql; 5.71.0 adds instance fields).
# `services` is project-wide; the services of one environment are its serviceInstances. `worker`
# exists only in staging, so a production inventory must not pick it up.
cat >"$T/fixture/status.json" <<'EOF'
{"id":"p1","name":"shop","deletedAt":null,"workspace":{"name":"Acme"},
 "environments":{"edges":[
  {"node":{"id":"e1","name":"production","canAccess":true,"deletedAt":null,
   "serviceInstances":{"edges":[{"node":{"id":"si1","serviceId":"s1","serviceName":"web","environmentId":"e1",
     "latestDeployment":null,"source":{"repo":"acme/web","image":null},
     "domains":{"serviceDomains":[{"id":"d1","domain":"web-production.up.railway.app","targetPort":8080}],"customDomains":[]},
     "cronSchedule":null,"nextCronRunAt":null,"startCommand":"node server.js"}}]},
   "volumeInstances":{"edges":[]}}},
  {"node":{"id":"e2","name":"staging","canAccess":true,"deletedAt":null,
   "serviceInstances":{"edges":[
     {"node":{"id":"si2","serviceId":"s1","serviceName":"web","environmentId":"e2","latestDeployment":null,
       "source":{"repo":"acme/web","image":null},"domains":{"serviceDomains":[],"customDomains":[]},
       "cronSchedule":null,"nextCronRunAt":null,"startCommand":"node server.js"}},
     {"node":{"id":"si3","serviceId":"s2","serviceName":"worker","environmentId":"e2","latestDeployment":null,
       "source":{"repo":"acme/worker","image":null},"domains":{"serviceDomains":[],"customDomains":[]},
       "cronSchedule":"*/5 * * * *","nextCronRunAt":null,"startCommand":null}}]},
   "volumeInstances":{"edges":[]}}}]},
 "services":{"edges":[{"node":{"id":"s1","name":"web"}},{"node":{"id":"s2","name":"worker"}}]}}
EOF
# 5.71.0 adds the environment instances (src/commands/status.rs, EnvironmentInstances.graphql), including
# the legacy numReplicas that reports 1 for multi-region services.
jq '(.environments.edges[].node.serviceInstances.edges[].node) += {numReplicas: 1}' \
  "$T/fixture/status.json" >"$T/fixture/status-5.json"
# `railway service list --json` on 5.x: one ServiceOutput per service in the environment
# (railwayapp/cli v5.71.0: src/commands/output/service_summary.rs).
cat >"$T/fixture/service-list.json" <<'EOF'
[{"id":"s1","name":"web","isLinked":false,"source":{"repo":"acme/web","image":null},"status":"SUCCESS",
  "deploymentStopped":false,"deploymentId":"dep1",
  "latestDeployment":{"id":"dep1","status":"SUCCESS","createdAt":"2026-10-20T12:00:00Z","deploymentStopped":false},
  "url":"https://web-production.up.railway.app","volumes":[],
  "regions":[{"name":"us-west2","location":"California, USA","configured":2}],
  "replicas":{"configured":2,"running":2,"crashed":0,"exited":0,"total":2},"volumeMigrating":false}]
EOF

# inventory <dir> [ENV=VALUE ...]   runs railway_inventory.sh in a new <dir> (each name used once)
inventory() {
  local dir="$1"; shift
  mkdir "$T/$dir"; : >"$T/fixture/calls.log"
  (cd "$T/$dir" && env "$@" "$SH" "$SCRIPTS/railway_inventory.sh" --project p1 >inv.out 2>&1) || true
}
INV=migration/inventory/railway

cd "$T"
echo "== old CLI (4.16.1): only \`railway variables\`"
inventory old FAKE_CLI=old
check "exports the service's variables" '[ "$(jq -r .count old/$INV/variables/web.json 2>/dev/null)" = "4" ]'
check "classifies them" '[ "$(jq -r ".variables[] | select(.name==\"OPENAI_API_KEY\") | .class" old/$INV/variables/web.json 2>/dev/null)" = "app_secret" ]'
check "values land in .secrets (mode 600)" 'grep >/dev/null 2>&1 "^OPENAI_API_KEY=" old/migration/.secrets/railway.web.env &&[ "$(stat -c %a old/migration/.secrets/railway.web.env 2>/dev/null || stat -f %Lp old/migration/.secrets/railway.web.env)" = "600" ]'
check "used \`railway variables\` with --json" 'grep >/dev/null "^variables -s web -e production --json$" fixture/calls.log'
check "no value outside .secrets" '! grep -Er "$FIXTURE_VALUES" old/$INV old/inv.out >/dev/null'
check "SUMMARY lists the variable names" 'grep >/dev/null "OPENAI_API_KEY" old/$INV/SUMMARY.md'

echo "== old CLI, --json broken: falls back to \`railway variables --kv\`"
inventory oldkv FAKE_CLI=old FAKE_JSON_BROKEN=1
check "exports the service's variables" '[ "$(jq -r .count oldkv/$INV/variables/web.json 2>/dev/null)" = "4" ]'
check "used \`railway variables\` with --kv" 'grep >/dev/null "^variables -s web -e production --kv$" fixture/calls.log'
check "no value outside .secrets" '! grep -Er "$FIXTURE_VALUES" oldkv/$INV oldkv/inv.out >/dev/null'

echo "== new CLI (5.x): \`railway variable list\` first"
inventory new FAKE_CLI=new
check "exports the service's variables" '[ "$(jq -r .count new/$INV/variables/web.json 2>/dev/null)" = "4" ]'
check "used \`variable list --json\`" 'grep >/dev/null "^variable list -s web -e production --json$" fixture/calls.log'
check "never called \`railway variables\`" '! grep >/dev/null "^variables " fixture/calls.log'

echo "== subcommand guard, old CLI (4.16.1): never runs a subcommand it does not have"
inventory guard_old FAKE_CLI=old
L=fixture/calls.log
E=guard_old/$INV/errors.log
check "no \`domain list\` call (4.16.1 reads it as \"add custom domain list\")" '! grep -E "^domain list" $L >/dev/null'
check "no \`service list\` call (4.16.1 reads it as \"link service list\")" '! grep -E "^service list" $L >/dev/null'
check "no \`environment list\` or \`environment config\` call" '! grep -E "^environment (list|config)" $L >/dev/null'
check "no call to top-level commands 4.16.1 lacks" '! grep -E "^(bucket|cron|config|postgres|usage) " $L >/dev/null'
check "subcommands 4.16.1 has still run" 'grep -x "service status --all --json" $L >/dev/null && grep -x "volume list --json" $L >/dev/null && grep -x "functions list" $L >/dev/null'
check "skips are logged in errors.log" 'grep -x "## \[domain list --json\] skipped: not in this CLI" $E >/dev/null && grep -x "## \[domain list -s web\] skipped: not in this CLI" $E >/dev/null && grep -x "## \[postgres ha status\] skipped: not in this CLI" $E >/dev/null'
check "help is read once per command" '[ "$(grep -cx -- "--help" $L)" = 1 ] && [ "$(grep -cx "service --help" $L)" = 1 ] && [ "$(grep -cx "domain --help" $L)" = 1 ]'
check "skips are not counted as command errors" 'grep "skipped (not in this CLI)=" guard_old/inv.out >/dev/null'
check "services are still found (from status --json)" 'grep -x web guard_old/$INV/services.txt >/dev/null'
check "only services of the target environment (not staging-only ones)" '[ "$(cat guard_old/$INV/services.txt)" = "web" ]'
check "variables are still exported" '[ "$(jq -r .count guard_old/$INV/variables/web.json 2>/dev/null)" = "4" ]'

echo "== subcommand guard, new CLI (5.x): runs them"
inventory guard_new FAKE_CLI=new
E=guard_new/$INV/errors.log
for c in "domain list --json" "domain list -s web --json" "service list --json" \
         "environment config --json" "environment list" "volume list --json" "bucket list --json" "cron list" \
         "functions list" "config pull --force" "postgres ha status --json" "postgres pgbouncer status --json" \
         "postgres pitr status --json" "usage projects --project shop --json"; do
  check "runs \`$c\`" 'grep -x -- "$c" $L >/dev/null'
done
check "nothing skipped" '! grep "skipped: not in this CLI" $E >/dev/null'
check "no deprecated \`service status --all\` call (\`service list --json\` has its data)" '! grep -E "^service status" $L >/dev/null'
check "summary uses \`service list --json\` (regions)" 'jq -e ".services[] | select(.name==\"web\") | .regions | tostring | test(\"us-west2\")" guard_new/$INV/services.normalized.json >/dev/null'
check "summary uses \`service list --json\` (replicas, not legacy numReplicas)" 'jq -e ".services[] | select(.name==\"web\") | .replicas.configured == 2" guard_new/$INV/services.normalized.json >/dev/null 2>&1'

echo "== re-run with an older CLI in the same directory"
mkdir rerun
(cd rerun && env FAKE_CLI=new "$SH" "$SCRIPTS/railway_inventory.sh" --project p1 >inv1.out 2>&1) || true
(cd rerun && env FAKE_CLI=old "$SH" "$SCRIPTS/railway_inventory.sh" --project p1 >inv2.out 2>&1) || true
check "first run wrote service list output" 'grep "service list --json .*ok" rerun/inv1.out >/dev/null'
check "skipped commands leave no stale output behind" '[ ! -e rerun/$INV/raw/services.json ] && [ ! -e rerun/$INV/raw/domains.json ] && [ ! -e rerun/$INV/raw/domains.web.json ]'
check "4.16.1 re-run falls back to \`service status --all\`" 'jq -e ".[0].name == \"web\"" rerun/$INV/raw/service-status.json >/dev/null 2>&1'

echo "== nothing works: logged, no secrets file"
inventory none FAKE_CLI=old FAKE_JSON_BROKEN=1 FAKE_KV_BROKEN=1
check "prints a FAILED line" 'grep >/dev/null "variables: web .*FAILED" none/inv.out'
check "errors.log records the failure" 'grep >/dev/null "^## \[variable list -s web\] failed" none/$INV/errors.log'
check "errors.log keeps the CLI's stderr" 'grep >/dev/null "unrecognized subcommand" none/$INV/errors.log && grep >/dev/null "kv listing failed" none/$INV/errors.log'
check "no secrets file and no inventory file" '[ ! -e none/migration/.secrets/railway.web.env ] && [ ! -e none/$INV/variables/web.json ]'
check "SUMMARY says the export failed" 'grep >/dev/null "variable export failed" none/$INV/SUMMARY.md'

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
