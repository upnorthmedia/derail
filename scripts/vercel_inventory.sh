#!/usr/bin/env bash
# vercel_inventory.sh - export a Vercel project's configuration for migration to AWS,
# WITHOUT printing any secret value.
#
#   stdout / SUMMARY.md / inventory       : names, counts, Config-vs-Secret classification
#   migration/.secrets/vercel.<env>.env   : `vercel env pull` output (umask 077, git-ignored).
#                                           Secret-type variables come back as placeholders:
#                                           they CANNOT be exported and must be re-sourced.
#
# Every CLI call is best-effort; failures go to <out>/errors.log and the script continues.
set -euo pipefail

PROJECT=""
TEAM=""
OUT="migration/inventory/vercel"
SECRETS_DIR="migration/.secrets"
REPO="."
SKIP_LINK=0
ENVS="production preview"

usage() {
  cat <<'EOF'
Usage: vercel_inventory.sh --project <name> [--team <slug>] [--repo .]
                           [--out migration/inventory/vercel] [--secrets-dir migration/.secrets]
                           [--envs "production preview"] [--skip-link] [--help]

Runs (best-effort, errors -> <out>/errors.log):
  vercel link --yes --project <name> [--scope <team>]      (in --repo)
  vercel project ls, vercel project inspect <name>
  vercel env ls <env>            -> names + Config/Secret type (values never stored in inventory)
  vercel env pull <secrets-dir>/vercel.<env>.env --environment=<env> --yes   (umask 077)
  vercel domains ls, vercel dns ls <domain> per custom domain
  vercel blob list               (only if BLOB_READ_WRITE_TOKEN is available; count + sample paths)
  copies vercel.json and next.config.* from --repo

Writes <out>/SUMMARY.md: framework, node version, domains, crons, env var names (Secret vs Config),
rewrites/redirects/headers presence, functions config.

Requires: vercel CLI (logged in), jq.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --project=*) PROJECT="${1#*=}"; shift ;;
    --team|--scope) TEAM="${2:-}"; shift 2 ;;
    --team=*|--scope=*) TEAM="${1#*=}"; shift ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --repo=*) REPO="${1#*=}"; shift ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --out=*) OUT="${1#*=}"; shift ;;
    --secrets-dir) SECRETS_DIR="${2:-}"; shift 2 ;;
    --secrets-dir=*) SECRETS_DIR="${1#*=}"; shift ;;
    --envs) ENVS="${2:-}"; shift 2 ;;
    --envs=*) ENVS="${1#*=}"; shift ;;
    --skip-link) SKIP_LINK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$PROJECT" ] || { echo "error: --project is required" >&2; usage >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
command -v vercel >/dev/null 2>&1 || { echo "error: vercel CLI not found (npm i -g vercel)" >&2; exit 1; }
[ -d "$REPO" ] || { echo "error: --repo '$REPO' is not a directory" >&2; exit 2; }

# absolute paths so we can cd into the repo for `vercel link`
OUT="$(mkdir -p "$OUT" && cd "$OUT" && pwd)"
( umask 077; mkdir -p "$SECRETS_DIR" )
SECRETS_DIR="$(cd "$SECRETS_DIR" && pwd)"
chmod 700 "$SECRETS_DIR" 2>/dev/null || true
REPO="$(cd "$REPO" && pwd)"
mkdir -p "$OUT/raw" "$OUT/env"

add_gitignore() {
  local root entry
  root="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || pwd)"
  entry="$SECRETS_DIR"
  case "$entry" in "$root"/*) entry="${entry#"$root"/}" ;; esac
  entry="${entry%/}/"
  if ! grep -qxF -- "$entry" "$root/.gitignore" 2>/dev/null; then
    printf '%s\n' "$entry" >>"$root/.gitignore"
    echo "gitignore: added '$entry' to $root/.gitignore"
  fi
}
add_gitignore

ERRLOG="$OUT/errors.log"
{
  echo "# vercel_inventory.sh errors - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# project=$PROJECT team=${TEAM:-<default>} repo=$REPO"
} >"$ERRLOG"

SCOPE_ARGS=()
[ -n "$TEAM" ] && SCOPE_ARGS=(--scope "$TEAM")

if ! vercel whoami "${SCOPE_ARGS[@]}" >/dev/null 2>&1; then
  echo "error: vercel CLI is not logged in (vercel login, or set VERCEL_TOKEN)" >&2
  exit 1
fi

# run <label> <outfile> -- cmd...  (best-effort; stdout -> outfile, stderr -> errors.log)
run() {
  local label="$1" outfile="$2"; shift 2
  [ "${1:-}" = "--" ] && shift
  local rc=0
  if "$@" >"$outfile" 2>>"$ERRLOG.tmp"; then rc=0; else rc=$?; fi
  if [ -s "$ERRLOG.tmp" ] || [ "$rc" -ne 0 ]; then
    { echo "## [$label] exit=$rc cmd: $*"; cat "$ERRLOG.tmp" 2>/dev/null; echo; } >>"$ERRLOG"
  fi
  rm -f "$ERRLOG.tmp"
  if [ "$rc" -ne 0 ]; then printf '  %-30s FAILED (exit %s, see errors.log)\n' "$label" "$rc"
  else printf '  %-30s ok (%s bytes)\n' "$label" "$(wc -c <"$outfile" | tr -d ' ')"; fi
  return "$rc"
}
strip_ansi() { sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g'; }

echo "== Vercel inventory: project=$PROJECT team=${TEAM:-<default>} -> $OUT"

# ---------------------------------------------------------------- link + project
if [ "$SKIP_LINK" -eq 0 ]; then
  ( cd "$REPO" && run "link" "$OUT/raw/link.txt" -- vercel link --yes --project "$PROJECT" "${SCOPE_ARGS[@]}" ) || true
fi
if [ -f "$REPO/.vercel/project.json" ]; then
  cp "$REPO/.vercel/project.json" "$OUT/raw/vercel-project-link.json"
fi
run "project ls" "$OUT/raw/project-ls.txt" -- vercel project ls "${SCOPE_ARGS[@]}" || true
run "project inspect" "$OUT/raw/project-inspect.txt" -- vercel project inspect "$PROJECT" "${SCOPE_ARGS[@]}" || true

# ---------------------------------------------------------------- env vars
# `vercel env ls` may show partial values on some versions -> raw output goes to SECRETS_DIR, not inventory.
for env in $ENVS; do
  rawls="$SECRETS_DIR/vercel.$env.env-ls.txt"
  ( umask 077; cd "$REPO" && run "env ls $env" "$rawls" -- vercel env ls "$env" "${SCOPE_ARGS[@]}" ) || true
  if [ -s "$rawls" ]; then
    # names + type from the table. A line is a variable row when its first token is an env-var name.
    strip_ansi <"$rawls" | awk -v env="$env" '
      $1 ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && $1 !~ /^(name|Name|NAME|Vercel|Retrieving|Environment|>)$/ && NF >= 2 {
        t = "unknown"
        if ($0 ~ /[Ss]ecret|[Ss]ensitive/) t = "secret"
        else if ($0 ~ /[Cc]onfig|[Pp]lain/) t = "config"
        else if ($0 ~ /[Ee]ncrypted/) t = "encrypted"
        print $1 "\t" t
      }' | sort -u >"$OUT/env/$env.names.tsv"
  else
    : >"$OUT/env/$env.names.tsv"
  fi

  pulled="$SECRETS_DIR/vercel.$env.env"
  ( umask 077; cd "$REPO" && run "env pull $env" "$OUT/raw/env-pull.$env.txt" -- vercel env pull "$pulled" --environment="$env" --yes "${SCOPE_ARGS[@]}" ) || true
  chmod 600 "$pulled" 2>/dev/null || true

  # Which pulled keys hold a real value vs. a placeholder? (names only)
  if [ -s "$pulled" ]; then
    awk '
      /^[[:space:]]*#/ || !/=/ { next }
      {
        line = $0; sub(/^[[:space:]]*export[[:space:]]+/, "", line)
        eq = index(line, "="); k = substr(line, 1, eq - 1); v = substr(line, eq + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
        if (k !~ /^[A-Za-z_][A-Za-z0-9_]*$/) next
        gsub(/^"|"$/, "", v)
        state = "real"
        if (v == "" ) state = "empty"
        else if (tolower(v) ~ /placeholder|replace_me|redacted|cannot be read|^\*+$|^<.*>$|^xxx+$/) state = "placeholder"
        print k "\t" state
      }' "$pulled" | sort -u >"$OUT/env/$env.pulled.tsv"
  else
    : >"$OUT/env/$env.pulled.tsv"
  fi

  # merge -> env/<env>.json (names, type from ls, pulled state, migration class)
  jq -Rn --arg env "$env" \
    --rawfile ls "$OUT/env/$env.names.tsv" --rawfile pulled "$OUT/env/$env.pulled.tsv" '
    def rows(s): s | split("\n") | map(select(length>0) | split("\t"));
    (rows($ls) | map({(.[0]): .[1]}) | add // {}) as $types
    | (rows($pulled) | map({(.[0]): .[1]}) | add // {}) as $pull
    | (($types|keys) + ($pull|keys) | unique) as $names
    | {
        environment: $env,
        count: ($names|length),
        variables: ($names | map(. as $n | {
            name: $n,
            type: ($types[$n] // "unknown"),
            pulled: ($pull[$n] // "not_in_pull"),
            class: (if ($n|startswith("VERCEL_")) then "vercel_system"
                    elif ($n|startswith("NEXT_PUBLIC_")) then "public_buildtime"
                    elif ($n|test("^(BLOB_READ_WRITE_TOKEN|BLOB_.*TOKEN)$")) then "vercel_blob"
                    elif ($n|test("^(KV_|UPSTASH_|EDGE_CONFIG|REDIS_URL|REDIS_)")) then "cache_kv"
                    elif ($n|test("^(DATABASE_URL|POSTGRES_|PG|DATABASE_URL_UNPOOLED|DIRECT_URL|NEON_)")) then "database"
                    elif ($n|test("^(CRON_SECRET|REVALIDATE_SECRET)$")) then "app_secret_internal"
                    else "app_secret" end),
            exportable: (if ($pull[$n] // "") == "real" then true
                         elif ($types[$n] // "") == "secret" or (($pull[$n] // "") | IN("placeholder","empty")) then false
                         else null end)
        })),
        secret_unexportable: ($names | map(select((($pull[.] // "") != "real") and ((($types[.] // "") == "secret") or (($pull[.] // "") | IN("placeholder","empty")))))),
        exported_real: ($names | map(select(($pull[.] // "") == "real")))
      }' >"$OUT/env/$env.json"
  printf '  env %-10s %s names, %s exportable, %s secret/placeholder\n' "$env" \
    "$(jq -r .count "$OUT/env/$env.json")" "$(jq -r '.exported_real|length' "$OUT/env/$env.json")" \
    "$(jq -r '.secret_unexportable|length' "$OUT/env/$env.json")"
done

# ---------------------------------------------------------------- domains + dns
run "domains ls" "$OUT/raw/domains-ls.txt" -- vercel domains ls "${SCOPE_ARGS[@]}" || true
DOMAINS=()
if [ -s "$OUT/raw/domains-ls.txt" ]; then
  while IFS= read -r d; do [ -n "$d" ] && DOMAINS+=("$d"); done < <(
    strip_ansi <"$OUT/raw/domains-ls.txt" | grep -oE '\b[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,}\b' \
      | grep -vE '\.(vercel\.app|vercel\.com|now\.sh)$' | sort -u)
fi
# project-level domains from `project inspect` (lines containing a hostname)
if [ -s "$OUT/raw/project-inspect.txt" ]; then
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    skip=0; for e in "${DOMAINS[@]:-}"; do [ "$e" = "$d" ] && skip=1; done
    [ "$skip" -eq 0 ] && DOMAINS+=("$d")
  done < <(strip_ansi <"$OUT/raw/project-inspect.txt" | grep -oE '\b[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,}\b' \
             | grep -vE '\.(vercel\.app|vercel\.com|now\.sh|git|js|ts|json|mjs)$' | sort -u)
fi
printf '%s\n' "${DOMAINS[@]:-}" | sed '/^$/d' >"$OUT/domains.txt"
echo "custom domains found: $(sed '/^$/d' "$OUT/domains.txt" | wc -l | tr -d ' ')"
for d in "${DOMAINS[@]:-}"; do
  [ -n "$d" ] || continue
  run "dns ls $d" "$OUT/raw/dns.$d.txt" -- vercel dns ls "$d" "${SCOPE_ARGS[@]}" || true
done

# ---------------------------------------------------------------- blob
# Token sourced from the environment or from the pulled production file; never printed.
blob_token=""
if [ -n "${BLOB_READ_WRITE_TOKEN:-}" ]; then
  blob_token="$BLOB_READ_WRITE_TOKEN"
elif [ -s "$SECRETS_DIR/vercel.production.env" ]; then
  blob_token="$(sed -nE 's/^(export[[:space:]]+)?BLOB_READ_WRITE_TOKEN=//p' "$SECRETS_DIR/vercel.production.env" | head -n1 | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')"
fi
if [ -n "$blob_token" ] && [[ "$blob_token" == vercel_blob_rw_* ]]; then
  ( export BLOB_READ_WRITE_TOKEN="$blob_token"; cd "$REPO" && run "blob list" "$OUT/raw/blob-list.txt" -- vercel blob list --limit 1000 ) || true
  if [ -s "$OUT/raw/blob-list.txt" ]; then
    strip_ansi <"$OUT/raw/blob-list.txt" | grep -oE 'https://[a-z0-9]+\.(public|private)\.blob\.vercel-storage\.com/[^[:space:]]+' | sort -u >"$OUT/blob-urls.txt" || true
    blob_count="$(wc -l <"$OUT/blob-urls.txt" | tr -d ' ')"
    echo "  blob objects listed: $blob_count (first page, limit 1000; use blob_to_s3.ts --dry-run for a full count)"
  fi
else
  echo "  blob list                      skipped (no usable BLOB_READ_WRITE_TOKEN in env or pulled production file)"
  echo "## [blob list] skipped: BLOB_READ_WRITE_TOKEN unavailable or placeholder" >>"$ERRLOG"
fi
unset blob_token

# ---------------------------------------------------------------- repo config files
for f in vercel.json next.config.js next.config.mjs next.config.ts next.config.cjs; do
  [ -f "$REPO/$f" ] && cp "$REPO/$f" "$OUT/$f" && echo "  copied $f"
done

# ---------------------------------------------------------------- summary
inspect_field() { # inspect_field <regex-label>
  strip_ansi <"$OUT/raw/project-inspect.txt" 2>/dev/null | grep -iE "$1" | head -n1 | sed -E 's/^[^:]*:[[:space:]]*//' || true
}
FRAMEWORK="$(inspect_field 'framework')"
NODE_VERSION="$(inspect_field 'node(\.js)? version')"
ROOT_DIR="$(inspect_field 'root directory')"
BUILD_CMD="$(inspect_field 'build command')"

VJ="$OUT/vercel.json"
has_vj=0; [ -f "$VJ" ] && jq -e . "$VJ" >/dev/null 2>&1 && has_vj=1

{
  echo "# Vercel inventory: $PROJECT"
  echo
  echo "Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by vercel_inventory.sh. Raw CLI output in \`raw/\`; errors in \`errors.log\`."
  echo "Pulled variable VALUES are in \`$SECRETS_DIR/vercel.<env>.env\` (git-ignored, mode 600) and never shown here."
  echo
  echo "## Project"
  echo
  echo "- framework: ${FRAMEWORK:-? (see raw/project-inspect.txt)}"
  echo "- node version: ${NODE_VERSION:-? (check package.json engines / .nvmrc via scan_codebase.py)}"
  echo "- root directory: ${ROOT_DIR:-? / repo root}"
  echo "- build command: ${BUILD_CMD:-default}"
  if [ -f "$OUT/raw/vercel-project-link.json" ]; then
    echo "- projectId: $(jq -r '.projectId // "?"' "$OUT/raw/vercel-project-link.json"), orgId: $(jq -r '.orgId // "?"' "$OUT/raw/vercel-project-link.json")"
  fi
  echo
  echo "## Custom domains ($(sed '/^$/d' "$OUT/domains.txt" | wc -l | tr -d ' '))"
  echo
  if [ -s "$OUT/domains.txt" ]; then sed 's/^/- /' "$OUT/domains.txt"; else echo "_none found; check raw/domains-ls.txt_"; fi
  echo
  echo "DNS records per domain are in \`raw/dns.<domain>.txt\` (import into Route 53; lower TTLs before cutover)."
  echo
  echo "## Environment variables"
  echo
  echo "**Secret-type variables cannot be exported from Vercel** (\`vercel env pull\` writes a placeholder)."
  echo "Each one must be re-sourced from its provider (Stripe, Twilio, Resend, ...) or rotated. Treat the migration as a secret-rotation event."
  echo
  for env in $ENVS; do
    f="$OUT/env/$env.json"; [ -f "$f" ] || continue
    echo "### $env ($(jq -r .count "$f") variables)"
    echo
    echo "| name | type (env ls) | pulled | class | exportable |"
    echo "|---|---|---|---|---|"
    jq -r '.variables[] | "| \(.name) | \(.type) | \(.pulled) | \(.class) | \(if .exportable==true then "yes" elif .exportable==false then "NO - re-source" else "unknown" end) |"' "$f"
    echo
    echo "- must re-source ($(jq -r '.secret_unexportable|length' "$f")): $(jq -r '.secret_unexportable | join(", ")' "$f")"
    echo "- exported with real values ($(jq -r '.exported_real|length' "$f")): $(jq -r '.exported_real | join(", ")' "$f")"
    echo "- NEXT_PUBLIC_* are inlined at build time: pass them as Docker build args, not runtime task env."
    echo "- VERCEL_* system variables are not available on AWS: replace with APP_URL / GIT_SHA you set yourself."
    echo
  done
  echo "## vercel.json"
  echo
  if [ "$has_vj" -eq 1 ]; then
    echo "- crons: $(jq -c '.crons // []' "$VJ")"
    echo "  - AWS: EventBridge rule -> API Destination (Authorization: Bearer CRON_SECRET) or Scheduler -> ECS RunTask. Schedules are UTC; AWS cron is 6-field."
    echo "- rewrites: $(jq -r '(.rewrites // []) | length' "$VJ") redirects: $(jq -r '(.redirects // []) | length' "$VJ") headers: $(jq -r '(.headers // []) | length' "$VJ")  (vercel.json routing is NOT honored off-Vercel: port to next.config.* or CloudFront/ALB rules)"
    echo "- functions: $(jq -c '.functions // {}' "$VJ")"
    echo "- regions: $(jq -c '.regions // []' "$VJ")  framework: $(jq -r '.framework // "n/a"' "$VJ")  buildCommand: $(jq -r '.buildCommand // "n/a"' "$VJ")  outputDirectory: $(jq -r '.outputDirectory // "n/a"' "$VJ")"
    echo "- cleanUrls: $(jq -r '.cleanUrls // false' "$VJ") trailingSlash: $(jq -r '.trailingSlash // "n/a"' "$VJ")"
  else
    echo "_no vercel.json in repo (or not valid JSON)_"
  fi
  echo
  echo "## next.config"
  echo
  nc="$(ls "$OUT"/next.config.* 2>/dev/null | head -n1 || true)"
  if [ -n "$nc" ]; then
    echo "- file: $(basename "$nc")"
    for key in "output" "standalone" "rewrites" "redirects" "headers" "images" "remotePatterns" "cacheHandler" "cacheMaxMemorySize" "experimental" "serverExternalPackages" "basePath" "assetPrefix" "deploymentId"; do
      if grep -qE "\b$key\b" "$nc"; then echo "- mentions \`$key\`"; fi
    done
  else
    echo "_no next.config.* found in repo_"
  fi
  echo
  echo "## Blob"
  echo
  if [ -s "$OUT/blob-urls.txt" ]; then
    echo "- objects listed (first page): $(wc -l <"$OUT/blob-urls.txt" | tr -d ' ')"
    echo "- sample paths:"
    head -n 10 "$OUT/blob-urls.txt" | sed -E 's#^https://[^/]+/#  - #'
    echo "- plan: blob_to_s3.ts (keeps pathname as S3 key; set S3_PREFIX to the Payload collection prefix)."
  else
    echo "_not listed (no token or no store). If the app uses @vercel/blob, obtain BLOB_READ_WRITE_TOKEN from the Storage tab and run blob_to_s3.ts --dry-run._"
  fi
  echo
  echo "## Files"
  echo
  echo '```'
  (cd "$OUT" && find . -type f | sort)
  echo '```'
} >"$OUT/SUMMARY.md"

errs="$(grep -c '^## \[' "$ERRLOG" || true)"
echo
echo "done: $OUT/SUMMARY.md  (command errors logged=$errs)"
