#!/usr/bin/env bash
# railway_inventory.sh - export everything about a Railway project/environment that a
# migration to AWS needs, WITHOUT printing any secret value.
#
#   stdout / SUMMARY.md / inventory JSON : names, counts, classifications, raw platform JSON
#   migration/.secrets/railway.<service>.env : variable VALUES (umask 077, git-ignored)
#
# Every Railway CLI call is best-effort: failures are appended to <out>/errors.log and the
# script continues. Raw JSON is always kept so a human (or Claude) can read shapes that this
# script's defensive jq did not anticipate. Re-running overwrites the same files (idempotent).
set -euo pipefail

PROJECT=""
ENVIRONMENT="production"
OUT="migration/inventory/railway"
SECRETS_DIR="migration/.secrets"
SKIP_LINK=0

usage() {
  cat <<'EOF'
Usage: railway_inventory.sh --project <id-or-name> [--environment production]
                            [--out migration/inventory/railway] [--secrets-dir migration/.secrets]
                            [--skip-link] [--help]

Runs (all best-effort, errors -> <out>/errors.log):
  railway link --project ... --environment ...
  railway status --json, environment config --json, service list --json (text fallback),
  domain list --json, volume list --json, bucket list --json,
  per service: variable list --json  (VALUES -> <secrets-dir>/railway.<service>.env, umask 077;
                                      NAMES + classification -> <out>/variables/<service>.json)
  railway config pull --force (in a temp dir; copies .railway/railway.ts + functions/)
  railway postgres ha|pgbouncer|pitr status --json, railway usage projects --json

Writes <out>/SUMMARY.md with a services table and variable names by class.

Variable classes: railway_injected, build_tuning, reference, database, bucket_credential,
                  public_buildtime, empty, sealed_unavailable, app_secret

Requires: railway CLI (logged in), jq. Optional: git (for .gitignore placement).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --project=*) PROJECT="${1#*=}"; shift ;;
    --environment|-e) ENVIRONMENT="${2:-}"; shift 2 ;;
    --environment=*) ENVIRONMENT="${1#*=}"; shift ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --out=*) OUT="${1#*=}"; shift ;;
    --secrets-dir) SECRETS_DIR="${2:-}"; shift 2 ;;
    --secrets-dir=*) SECRETS_DIR="${1#*=}"; shift ;;
    --skip-link) SKIP_LINK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$PROJECT" ] || { echo "error: --project is required" >&2; usage >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required (apt install jq | brew install jq)" >&2; exit 1; }
command -v railway >/dev/null 2>&1 || { echo "error: railway CLI not found (npm i -g @railway/cli)" >&2; exit 1; }

# ---------------------------------------------------------------- setup
mkdir -p "$OUT/raw" "$OUT/variables" "$OUT/railway-config"
( umask 077; mkdir -p "$SECRETS_DIR" )
chmod 700 "$SECRETS_DIR" 2>/dev/null || true
# absolute paths: later steps cd into a temp dir for `railway config pull`
OUT="$(cd "$OUT" && pwd)"
SECRETS_DIR="$(cd "$SECRETS_DIR" && pwd)"

# .gitignore: add the secrets dir at the repo root (or cwd if not a git repo)
add_gitignore() {
  local root entry
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  entry="$SECRETS_DIR"
  case "$entry" in /*) entry="${entry#"$root"/}" ;; esac
  entry="${entry%/}/"
  if ! grep -qxF -- "$entry" "$root/.gitignore" 2>/dev/null; then
    printf '%s\n' "$entry" >>"$root/.gitignore"
    echo "gitignore: added '$entry' to $root/.gitignore"
  fi
}
add_gitignore

ERRLOG="$OUT/errors.log"
: >"$ERRLOG"
{
  echo "# railway_inventory.sh errors - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# project=$PROJECT environment=$ENVIRONMENT"
} >>"$ERRLOG"

if ! railway whoami >/dev/null 2>&1; then
  echo "error: railway CLI is not logged in (railway login --browserless, or set RAILWAY_API_TOKEN)" >&2
  exit 1
fi

# run <label> <outfile> -- cmd args...   best-effort; stdout -> outfile, stderr -> errors.log
# Returns the command's exit status (callers must not let it abort the script).
run() {
  local label="$1" outfile="$2"; shift 2
  [ "${1:-}" = "--" ] && shift
  local rc=0
  if "$@" >"$outfile" 2>>"$ERRLOG.tmp"; then rc=0; else rc=$?; fi
  if [ -s "$ERRLOG.tmp" ] || [ "$rc" -ne 0 ]; then
    { echo "## [$label] exit=$rc cmd: $*"; cat "$ERRLOG.tmp" 2>/dev/null; echo; } >>"$ERRLOG"
  fi
  rm -f "$ERRLOG.tmp"
  if [ "$rc" -ne 0 ]; then
    printf '  %-28s FAILED (exit %s, see errors.log)\n' "$label" "$rc"
  else
    printf '  %-28s ok (%s bytes)\n' "$label" "$(wc -c <"$outfile" | tr -d ' ')"
  fi
  return "$rc"
}

is_json() { jq -e . "$1" >/dev/null 2>&1; }

echo "== Railway inventory: project=$PROJECT environment=$ENVIRONMENT -> $OUT"

# ---------------------------------------------------------------- link
if [ "$SKIP_LINK" -eq 0 ]; then
  run "link" "$OUT/raw/link.txt" -- railway link --project "$PROJECT" --environment "$ENVIRONMENT" || true
fi

# ---------------------------------------------------------------- project-level exports
run "status --json" "$OUT/raw/status.json" -- railway status --json || true
run "environment config --json" "$OUT/raw/environment-config.json" -- railway environment config --json || true
if ! run "service list --json" "$OUT/raw/services.json" -- railway service list --json || ! is_json "$OUT/raw/services.json"; then
  run "service list (text)" "$OUT/raw/services.txt" -- railway service list || true
fi
run "domain list --json" "$OUT/raw/domains.json" -- railway domain list --json || true
run "volume list --json" "$OUT/raw/volumes.json" -- railway volume list --json || true
run "bucket list --json" "$OUT/raw/buckets.json" -- railway bucket list --json || true
run "service status --all --json" "$OUT/raw/service-status.json" -- railway service status --all --json || true
run "cron list" "$OUT/raw/crons.txt" -- railway cron list || true
run "functions list" "$OUT/raw/functions.txt" -- railway functions list || true
run "environment list" "$OUT/raw/environments.txt" -- railway environment list || true

# ---------------------------------------------------------------- service names
# Try several JSON shapes, then the text output, then status.json.
services_from_json() {
  local f="$1"
  is_json "$f" || return 1
  jq -r '
    def names: (.. | objects | select(has("name") and (.name|type=="string")) | .name);
    if type=="array" then [ .[] | (.name // .serviceName // empty) ]
    elif has("services") then [ (.services | if type=="array" then .[] else (.edges[]?.node // .[]) end) | (.name // empty) ]
    else [ names ] end
    | unique | .[]' "$f" 2>/dev/null
}

SERVICES=()
if [ -s "$OUT/raw/services.json" ]; then
  while IFS= read -r s; do [ -n "$s" ] && SERVICES+=("$s"); done < <(services_from_json "$OUT/raw/services.json" || true)
fi
if [ ${#SERVICES[@]} -eq 0 ] && [ -s "$OUT/raw/services.txt" ]; then
  # text fallback: take the first token of each non-empty, non-header line
  while IFS= read -r s; do [ -n "$s" ] && SERVICES+=("$s"); done < <(
    sed -E 's/\x1b\[[0-9;]*m//g' "$OUT/raw/services.txt" | awk 'NF && $1 !~ /^(NAME|Service|Services|ID|-+)$/ {print $1}' | sort -u)
fi
if [ ${#SERVICES[@]} -eq 0 ] && is_json "$OUT/raw/status.json"; then
  while IFS= read -r s; do [ -n "$s" ] && SERVICES+=("$s"); done < <(
    jq -r '[.services.edges[]?.node.name?, .services[]?.name?, (.. | objects | select(has("serviceName")) | .serviceName)] | map(select(type=="string")) | unique | .[]' "$OUT/raw/status.json" 2>/dev/null || true)
fi
printf '%s\n' "${SERVICES[@]}" >"$OUT/services.txt"
echo "services discovered: ${#SERVICES[@]}"

# ---------------------------------------------------------------- config pull (railway.ts)
# Done in a temp dir so the user's repo is not touched. No --include-variables: values stay out.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
(
  cd "$TMP" || exit 1
  if [ "$SKIP_LINK" -eq 0 ]; then
    railway link --project "$PROJECT" --environment "$ENVIRONMENT" >/dev/null 2>>"$ERRLOG" || true
  fi
  railway config pull --force >"$TMP/config-pull.out" 2>>"$ERRLOG" || echo "## [config pull] failed" >>"$ERRLOG"
) || true
if [ -f "$TMP/.railway/railway.ts" ]; then
  cp "$TMP/.railway/railway.ts" "$OUT/railway-config/railway.ts"
  [ -d "$TMP/.railway/functions" ] && cp -R "$TMP/.railway/functions" "$OUT/railway-config/"
  echo "  config pull                  ok -> railway-config/railway.ts"
else
  echo "  config pull                  no railway.ts produced (see errors.log)"
fi

# Parse railway.ts: per-service sealed (preserve()) names and a few settings. Approximate.
RTS="$OUT/railway-config/railway.ts"
: >"$OUT/railway-config/preserve-vars.tsv"
: >"$OUT/railway-config/service-settings.tsv"
if [ -f "$RTS" ]; then
  cur=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ (service|fn|postgres|redis|mysql|mongo)\(\"([^\"]+)\" ]]; then
      cur="${BASH_REMATCH[2]}"
    fi
    [ -n "$cur" ] || continue
    rest="$line"
    while [[ "$rest" =~ ([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*:[[:space:]]*preserve\(\)(.*)$ ]]; do
      printf '%s\t%s\n' "$cur" "${BASH_REMATCH[1]}" >>"$OUT/railway-config/preserve-vars.tsv"
      rest="${BASH_REMATCH[2]}"
    done
    if [[ "$line" =~ (source:|build:|start:|preDeploy:|healthcheck|replicas:|domains:|cronSchedule|volumeMounts|tcpProxy) ]]; then
      trimmed="${line#"${line%%[![:space:]]*}"}"
      printf '%s\t%s\n' "$cur" "$trimmed" >>"$OUT/railway-config/service-settings.tsv"
    fi
  done <"$RTS"
fi

# ---------------------------------------------------------------- per-service exports
classify_jq='
  def dbnames: ["DATABASE_URL","DATABASE_PUBLIC_URL","DATABASE_UNPOOLED_URL","DATABASE_PUBLIC_UNPOOLED_URL",
                "REDIS_URL","REDIS_PUBLIC_URL","MYSQL_URL","MYSQL_PUBLIC_URL","MONGO_URL","MONGO_PUBLIC_URL",
                "PGHOST","PGPORT","PGUSER","PGPASSWORD","PGDATABASE","PGDATA","POSTGRES_DB","POSTGRES_USER","POSTGRES_PASSWORD",
                "REDISHOST","REDISPORT","REDISUSER","REDISPASSWORD","MYSQLHOST","MYSQLPORT","MYSQLUSER","MYSQLPASSWORD","MYSQLDATABASE",
                "MYSQL_ROOT_PASSWORD","MONGOHOST","MONGOPORT","MONGOUSER","MONGOPASSWORD"];
  def bucketnames: ["BUCKET","ACCESS_KEY_ID","SECRET_ACCESS_KEY","REGION","ENDPOINT",
                    "AWS_ACCESS_KEY_ID","AWS_SECRET_ACCESS_KEY","AWS_ENDPOINT_URL","AWS_S3_BUCKET_NAME","AWS_REGION","AWS_DEFAULT_REGION"];
  def classify($k; $v):
    ($v|tostring) as $s
    | if ($k|startswith("RAILWAY_")) then "railway_injected"
    elif ($k|test("^(RAILPACK_|NIXPACKS_|NO_CACHE$)")) then "build_tuning"
    elif ($s|contains("${{")) then "reference"
    elif (dbnames|index($k)) != null then "database"
    elif ($s|test("^(postgres(ql)?|mysql|mongodb(\\+srv)?|redis(s)?)://")) then "database"
    elif (bucketnames|index($k)) != null then "bucket_credential"
    elif ($s|test("storageapi\\.dev")) then "bucket_credential"
    elif ($k|test("^(NEXT_PUBLIC_|VITE_|PUBLIC_|REACT_APP_|NUXT_PUBLIC_|EXPO_PUBLIC_)")) then "public_buildtime"
    elif ($s=="") then "empty"
    else "app_secret" end;
  # normalise {K:V} | [{name,value}] | [{key,value}] | {variables:{...}}
  def entries:
    if type=="object" and has("variables") then (.variables|entries)
    elif type=="object" then to_entries
    elif type=="array" then map({key:(.name // .key // .Name), value:(.value // .Value // "")})
    else [] end;
  entries | map(select(.key|type=="string"))
'

for svc in "${SERVICES[@]}"; do
  safe="$(printf '%s' "$svc" | tr -c 'A-Za-z0-9._-' '_')"
  rawvars="$TMP/vars.$safe.json"      # values live only in TMP (mode 700) and SECRETS_DIR
  rc=0
  ( umask 077; railway variable list -s "$svc" -e "$ENVIRONMENT" --json >"$rawvars" 2>>"$ERRLOG" ) || rc=$?
  if [ "$rc" -ne 0 ] || ! is_json "$rawvars"; then
    # fallback: --kv (KEY=VALUE lines) -> convert to JSON object
    rc=0
    ( umask 077; railway variable list -s "$svc" -e "$ENVIRONMENT" --kv >"$TMP/vars.$safe.kv" 2>>"$ERRLOG" ) || rc=$?
    if [ "$rc" -eq 0 ] && [ -s "$TMP/vars.$safe.kv" ]; then
      ( umask 077; jq -Rn '[inputs | select(test("^[A-Za-z_][A-Za-z0-9_]*=")) | capture("^(?<key>[^=]+)=(?<value>.*)$")] | from_entries' "$TMP/vars.$safe.kv" >"$rawvars" )
    else
      echo "## [variable list -s $svc] failed (exit $rc)" >>"$ERRLOG"
      printf '  variables: %-20s FAILED (see errors.log)\n' "$svc"
      continue
    fi
  fi

  # VALUES -> secrets dir (dotenv, JSON-escaped double-quoted values)
  ( umask 077; jq -r "$classify_jq | .[] | \"\(.key)=\(.value|tostring|tojson)\"" "$rawvars" >"$SECRETS_DIR/railway.$safe.env" )
  chmod 600 "$SECRETS_DIR/railway.$safe.env" 2>/dev/null || true

  # NAMES + class -> inventory (no values)
  jq --arg svc "$svc" --arg env "$ENVIRONMENT" \
     --rawfile preserve "$OUT/railway-config/preserve-vars.tsv" \
     "$classify_jq"' as $e
     | ($preserve | split("\n") | map(select(length>0) | split("\t") | select(.[0]==$svc) | .[1])) as $sealed_candidates
     | ($e | map(.key)) as $present
     | {
         service: $svc, environment: $env,
         count: ($e|length),
         variables: ($e | map({name: .key, class: classify(.key; .value), value_length: ((.value|tostring)|length),
                               references: ([(.value|tostring) | scan("\\$\\{\\{[^}]+\\}\\}")] | unique)})),
         sealed_unavailable: ($sealed_candidates | map(select(. as $n | ($present|index($n))|not)) | unique),
         by_class: ($e | map(classify(.key; .value)) | group_by(.) | map({(.[0]): length}) | add // {})
       }' "$rawvars" >"$OUT/variables/$safe.json"

  n="$(jq -r '.count' "$OUT/variables/$safe.json")"
  sealed="$(jq -r '.sealed_unavailable|length' "$OUT/variables/$safe.json")"
  printf '  variables: %-20s %s vars (%s sealed/unavailable) -> %s/railway.%s.env\n' "$svc" "$n" "$sealed" "$SECRETS_DIR" "$safe"

  # per-service domain list (some CLI versions scope domains to the linked service)
  run "domain list -s $svc" "$OUT/raw/domains.$safe.json" -- railway domain list -s "$svc" --json >/dev/null 2>&1 || true
done

# ---------------------------------------------------------------- postgres add-ons, usage
run "postgres ha status" "$OUT/raw/postgres-ha.json" -- railway postgres ha status --json || true
run "postgres pgbouncer status" "$OUT/raw/postgres-pgbouncer.json" -- railway postgres pgbouncer status --json || true
run "postgres pitr status" "$OUT/raw/postgres-pitr.json" -- railway postgres pitr status --json || true

PROJECT_NAME="$PROJECT"
if is_json "$OUT/raw/status.json"; then
  PROJECT_NAME="$(jq -r '.name // .project.name // .projectName // empty' "$OUT/raw/status.json" 2>/dev/null || true)"
  PROJECT_NAME="${PROJECT_NAME:-$PROJECT}"
fi
run "usage projects" "$OUT/raw/usage.json" -- railway usage projects --project "$PROJECT_NAME" --json || true

# ---------------------------------------------------------------- normalized services + SUMMARY.md
# Heuristic merge of status.json / environment-config.json / service-status.json / railway.ts.
# Field names differ across CLI versions; anything not found is "?" and the raw files are listed.
status_file="$OUT/raw/status.json"; is_json "$status_file" || status_file=/dev/null
envcfg_file="$OUT/raw/environment-config.json"; is_json "$envcfg_file" || envcfg_file=/dev/null
svcstat_file="$OUT/raw/service-status.json"; is_json "$svcstat_file" || svcstat_file=/dev/null
domains_file="$OUT/raw/domains.json"; is_json "$domains_file" || domains_file=/dev/null
volumes_file="$OUT/raw/volumes.json"; is_json "$volumes_file" || volumes_file=/dev/null
buckets_file="$OUT/raw/buckets.json"; is_json "$buckets_file" || buckets_file=/dev/null

jq -n \
  --slurpfile status <(jq -c . "$status_file" 2>/dev/null || echo null) \
  --slurpfile envcfg <(jq -c . "$envcfg_file" 2>/dev/null || echo null) \
  --slurpfile svcstat <(jq -c . "$svcstat_file" 2>/dev/null || echo null) \
  --slurpfile domains <(jq -c . "$domains_file" 2>/dev/null || echo null) \
  --slurpfile volumes <(jq -c . "$volumes_file" 2>/dev/null || echo null) \
  --slurpfile buckets <(jq -c . "$buckets_file" 2>/dev/null || echo null) \
  --rawfile svcnames "$OUT/services.txt" \
  --rawfile settings "$([ -f "$OUT/railway-config/service-settings.tsv" ] && echo "$OUT/railway-config/service-settings.tsv" || echo /dev/null)" \
  --arg vardir "$OUT/variables" '
  def objs_named($n): [ .. | objects | select((.name? // .serviceName? // "") == $n) ];
  def first_of(paths): [ paths ] | map(select(. != null and . != "" and . != [] and . != {})) | .[0] // "?";
  def pick($o; $k): [ $o[] | .. | objects | select(has($k)) | .[$k] ] | map(select(. != null)) | .[0];
  ($svcnames | split("\n") | map(select(length>0))) as $names
  | ($settings | split("\n") | map(select(length>0) | split("\t") | {svc: .[0], line: .[1]})) as $ts
  | {
      services: [ $names[] as $n
        | ( ($status[0] // {}) | objs_named($n) ) as $s
        | ( ($envcfg[0] // {}) | objs_named($n) ) as $c
        | ( ($svcstat[0] // {}) | objs_named($n) ) as $st
        | ($s + $c + $st) as $all
        | ([ $ts[] | select(.svc==$n) | .line ]) as $tslines
        | {
            name: $n,
            source: first_of(pick($all;"repo"), pick($all;"image"), pick($all;"source"), ($tslines | map(select(startswith("source:"))) | .[0])),
            builder: first_of(pick($all;"builder"), pick($all;"buildCommand")),
            start_command: first_of(pick($all;"startCommand"), ($tslines | map(select(startswith("start:"))) | .[0])),
            healthcheck: first_of(pick($all;"healthcheckPath"), ($tslines | map(select(startswith("healthcheck"))) | .[0])),
            replicas: first_of(pick($all;"numReplicas"), pick($all;"replicas"), pick($all;"multiRegionConfig"), ($tslines | map(select(startswith("replicas:"))) | .[0])),
            regions: first_of(pick($all;"region"), pick($all;"regions"), (pick($all;"multiRegionConfig") | if type=="object" then keys else null end)),
            cron: first_of(pick($all;"cronSchedule"), ($tslines | map(select(test("cron"))) | .[0])),
            volumes: first_of(pick($all;"volumeMounts"), pick($all;"volumes"), ($tslines | map(select(startswith("volumeMounts"))) | .[0])),
            domains: first_of(pick($all;"domains"), pick($all;"customDomains"), pick($all;"serviceDomains"), ($tslines | map(select(startswith("domains:"))) | .[0])),
            tcp_proxies: first_of(pick($all;"tcpProxies"), pick($all;"tcpProxy"), ($tslines | map(select(test("tcpProxy"))) | .[0])),
            sleep: first_of(pick($all;"sleepApplication")),
            restart_policy: first_of(pick($all;"restartPolicyType")),
            pre_deploy: first_of(pick($all;"preDeployCommand"), ($tslines | map(select(startswith("preDeploy:"))) | .[0])),
            railway_ts_lines: $tslines
          } ],
      domains_raw_present: ($domains[0] != null),
      volumes_raw_present: ($volumes[0] != null),
      buckets_raw_present: ($buckets[0] != null),
      bucket_names: ([ ($buckets[0] // empty) | .. | objects | select(has("name")) | .name ] | unique),
      volume_names: ([ ($volumes[0] // empty) | .. | objects | select(has("name")) | .name ] | unique),
      domain_hosts: ([ ($domains[0] // empty) | .. | objects | (.domain? // .host? // .hostname? // empty) ] | map(select(type=="string")) | unique)
    }' >"$OUT/services.normalized.json" 2>>"$ERRLOG" || echo '{"services":[]}' >"$OUT/services.normalized.json"

# Merge per-service variable class info into one file
jq -s 'map({(.service): {count, by_class, sealed_unavailable, names_by_class: (.variables | group_by(.class) | map({(.[0].class): map(.name)}) | add // {})}}) | add // {}' \
  "$OUT"/variables/*.json >"$OUT/variables.summary.json" 2>/dev/null || echo '{}' >"$OUT/variables.summary.json"

# SUMMARY.md
{
  echo "# Railway inventory: $PROJECT_NAME / $ENVIRONMENT"
  echo
  echo "Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by railway_inventory.sh. Raw CLI output is in \`raw/\`;"
  echo "variable VALUES are in \`$SECRETS_DIR/railway.<service>.env\` (git-ignored, mode 600) and are never shown here."
  echo "Errors (if any) are in \`errors.log\`. Fields shown as \`?\` were not found in this CLI version's JSON; read \`raw/status.json\`."
  echo
  echo "## Services (${#SERVICES[@]})"
  echo
  echo "| name | source | builder | start command | healthcheck | replicas | regions | cron | volumes | domains | tcp proxies | pre-deploy | restart | sleep |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
  jq -r '.services[] | [.name, .source, .builder, .start_command, .healthcheck, .replicas, .regions, .cron, .volumes, .domains, .tcp_proxies, .pre_deploy, .restart_policy, .sleep]
         | map(if type=="string" then . else tojson end | gsub("\\|";"\\\\|") | gsub("\n";" ") | .[0:80]) | "| " + join(" | ") + " |"' "$OUT/services.normalized.json" 2>/dev/null || true
  echo
  echo "## Variables by service and class (names only)"
  echo
  for svc in "${SERVICES[@]}"; do
    safe="$(printf '%s' "$svc" | tr -c 'A-Za-z0-9._-' '_')"
    f="$OUT/variables/$safe.json"
    [ -f "$f" ] || { echo "### $svc"; echo; echo "_variable export failed; see errors.log_"; echo; continue; }
    echo "### $svc ($(jq -r .count "$f") variables)"
    echo
    jq -r '
      (.variables | group_by(.class) | map({class: .[0].class, names: map(.name)})) as $g
      | ($g[] | "- **\(.class)** (\(.names|length)): " + (.names | join(", "))),
        (if (.sealed_unavailable|length) > 0 then "- **sealed_unavailable** (\(.sealed_unavailable|length)): " + (.sealed_unavailable|join(", ")) + "  <- values cannot be exported; re-issue out-of-band" else empty end),
        ((.variables | map(select(.references|length>0)) | if length>0 then "- reference graph: " + (map("\(.name) -> \(.references|join(","))") | join("; ")) else empty end))
    ' "$f"
    echo
  done
  echo "## Project-level resources"
  echo
  echo "- buckets: $(jq -r '.bucket_names | if length>0 then join(", ") else "none found (see raw/buckets.json)" end' "$OUT/services.normalized.json" 2>/dev/null)"
  echo "- volumes: $(jq -r '.volume_names | if length>0 then join(", ") else "none found (see raw/volumes.json)" end' "$OUT/services.normalized.json" 2>/dev/null)"
  echo "- domains: $(jq -r '.domain_hosts | if length>0 then join(", ") else "none found (see raw/domains*.json)" end' "$OUT/services.normalized.json" 2>/dev/null)"
  for f in postgres-ha postgres-pgbouncer postgres-pitr; do
    if is_json "$OUT/raw/$f.json"; then
      echo "- $f: $(jq -c . "$OUT/raw/$f.json" | cut -c1-200)"
    else
      echo "- $f: not available (command failed or no Postgres add-on; see errors.log)"
    fi
  done
  if is_json "$OUT/raw/usage.json"; then
    echo "- usage (raw/usage.json): $(jq -c . "$OUT/raw/usage.json" | cut -c1-200)"
  else
    echo "- usage: not available"
  fi
  echo
  echo "## Files"
  echo
  echo '```'
  (cd "$OUT" && find . -type f | sort)
  echo '```'
  echo
  echo "## Next steps"
  echo
  echo "1. Read \`railway-config/railway.ts\` (source of truth for sources, start commands, healthchecks, replicas, domains, references)."
  echo "2. For every **sealed_unavailable** and **app_secret** name decide: re-use value (from .secrets) or rotate."
  echo "3. **reference** variables point at other services (e.g. \`\${{Postgres.DATABASE_URL}}\`): re-point them at RDS/ElastiCache/S3 on AWS."
  echo "4. **railway_injected** / **build_tuning** variables are not copied to AWS; provide PORT and friends in the task definition."
  echo "5. Run \`scan_codebase.py\` on the repo and \`estimate_cost.py\` with the replica/size numbers above."
} >"$OUT/SUMMARY.md"

errs="$(grep -c '^## \[' "$ERRLOG" || true)"
echo
echo "done: $OUT/SUMMARY.md  (services=${#SERVICES[@]}, command errors logged=$errs)"
