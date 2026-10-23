#!/usr/bin/env bash
# breach_check.sh - "am I exposed?" after Railway's 2026-10-21 environment-variable breach.
#
# Walks every Railway project, environment and service the logged-in CLI can see and writes a
# prioritised rotation checklist of variable NAMES (AI provider keys first). Needs only the Railway
# CLI and jq: no AWS account, no migration in progress.
#
#   --fingerprint FILE  also record a fingerprint (sha256, see lib/fingerprint.sh) of every current
#                       value. Run this BEFORE rotating anything: it is the record of what was exposed.
#   --verify FILE       re-read Railway and list every variable that still holds a value from FILE,
#                       i.e. was not rotated yet. Exit 1 if any remain, 3 if none were found but some
#                       services could not be read (the check is incomplete).
#
# Values are read into a umask 077 temp dir, classified and fingerprinted, then deleted. They are
# never printed, never written to the checklist, and never passed as arguments.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fingerprint.sh
. "$SCRIPT_DIR/lib/fingerprint.sh"
# shellcheck source=lib/gitignore.sh
. "$SCRIPT_DIR/lib/gitignore.sh"

OUT="railway-exposure.md"
FINGERPRINT=""
VERIFY=""
PROJECTS=()
ENVIRONMENTS=()

usage() {
  cat <<'EOF'
Usage: breach_check.sh [--project <id-or-name>]... [--environment <name>]...
                       [--out railway-exposure.md]
                       [--fingerprint migration/.secrets/railway.burned.sha256]
                       [--verify migration/.secrets/railway.burned.sha256]

Default: every project from `railway list --json`, every environment, every service.

  --project       limit to these projects (id or name; repeatable)
  --environment   limit to these environment names (repeatable)
  --out           checklist path (Markdown, names only). Default ./railway-exposure.md
  --fingerprint   write value fingerprints here (mode 600). Run before you rotate anything; later,
                  `put_secrets.sh` refuses any value whose fingerprint is in this file, and
                  `--verify` uses it to prove rotation is complete.
  --verify        compare current values against a fingerprint file; lists variables that still
                  hold an exposed value. Exit 1 if any do; exit 3 if none do but some services could
                  not be read, so the check is incomplete.

Output never contains a value. Sealed variables cannot be read by the CLI, so they are not listed:
check each service in the Railway dashboard for sealed variables and rotate those too.

Requires: railway CLI (logged in), jq, sha256sum or shasum.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECTS+=("${2:-}"); shift 2 ;;
    --project=*) PROJECTS+=("${1#*=}"); shift ;;
    --environment|-e) ENVIRONMENTS+=("${2:-}"); shift 2 ;;
    --environment=*) ENVIRONMENTS+=("${1#*=}"); shift ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --out=*) OUT="${1#*=}"; shift ;;
    --fingerprint) FINGERPRINT="${2:-}"; shift 2 ;;
    --fingerprint=*) FINGERPRINT="${1#*=}"; shift ;;
    --verify) VERIFY="${2:-}"; shift 2 ;;
    --verify=*) VERIFY="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "error: jq is required (brew install jq | apt install jq)" >&2; exit 1; }
command -v railway >/dev/null 2>&1 || { echo "error: railway CLI not found (npm i -g @railway/cli)" >&2; exit 1; }
if [ -n "$VERIFY" ] && [ ! -s "$VERIFY" ]; then
  echo "error: --verify file '$VERIFY' is missing or empty" >&2; exit 2
fi
if ! railway whoami >/dev/null 2>&1; then
  echo "error: railway CLI is not logged in (railway login, or set RAILWAY_API_TOKEN)" >&2; exit 1
fi

# Private from the first mkdir: --fingerprint's directory also receives the exported env files later.
umask 077

# Absolute paths: the Railway CLI runs from a temp link dir, and redirections inside that subshell
# resolve relative paths against it.
abspath() { mkdir -p "$(dirname "$1")" && printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"; }
OUT="$(abspath "$OUT")"
[ -n "$FINGERPRINT" ] && FINGERPRINT="$(abspath "$FINGERPRINT")"
[ -n "$VERIFY" ] && VERIFY="$(abspath "$VERIFY")"
if [ -n "$FINGERPRINT" ] && [ -n "$VERIFY" ]; then
  [ "$FINGERPRINT" != "$VERIFY" ] || { echo "error: --fingerprint and --verify must be different files" >&2; exit 2; }
fi
# The fingerprint file is the record of the exposed values. Re-running after rotation has started would
# mix in new values, so never replace it: moving it aside has to be deliberate.
if [ -n "$FINGERPRINT" ] && [ -s "$FINGERPRINT" ]; then
  echo "error: fingerprint file '$FINGERPRINT' already exists. It records the exposed values; to check" >&2
  echo "       rotation use --verify with it. To start over on purpose, move it aside first." >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ERRLOG="${OUT%.md}.errors.log"
: >"$ERRLOG"
ROWS="$TMP/rows.tsv"            # order<TAB>group<TAB>KEY<TAB>location<TAB>rotation hint (may be empty)
: >"$ROWS"
FP_NEW="$TMP/fingerprints.tsv"  # fingerprint<TAB>location/KEY
: >"$FP_NEW"
STILL="$TMP/still-exposed.tsv"  # location/KEY
: >"$STILL"
SKIPPED_CONFIG=0
FAILED=0

classify_jq="$(cat "$SCRIPT_DIR/lib/classify_vars.jq")"
# Names-only priority groups. First match wins, so provider prefixes come before generic suffixes.
# Rows use: order, group label, key. Classes that are not secrets are dropped; short values with
# config-looking names are counted as config instead of cluttering the checklist.
#
# Rotation hints: whether the provider lets the old and new credential work at the same time. Taken
# only from the provider table in references/breach-response.md section 4; keep the two in step.
# Exact names (plus a value-shape check where a name alone is ambiguous). Anything else gets no hint.
group_jq="$classify_jq"'
  | def rotation_hint($k; $v; $iam):
      if $k == "OPENAI_API_KEY" then "two live: yes"
      elif $k == "ANTHROPIC_API_KEY" then "two live: yes; Anthropic advises revoking at once"
      elif ($k | IN("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY")) and $iam then "two live: yes, 2 keys per IAM user"
      elif ((try ($v | fromjson | .type) catch null) == "service_account") then "two live: yes, up to 10 keys per service account"
      elif ($k | startswith("STRIPE_")) and ($v | test("^(sk|rk)_(live|test)_")) then "two live: grace, up to 7 days"
      elif ($k | startswith("STRIPE_")) and ($v | startswith("whsec_")) then "two live: grace, up to 24 hours"
      elif ($k | IN("GITHUB_TOKEN", "GH_TOKEN", "GITHUB_PAT", "GH_PAT", "GITHUB_PERSONAL_ACCESS_TOKEN")) then "two live: yes, if a personal access token"
      elif ($k | IN("GITHUB_CLIENT_SECRET", "GITHUB_OAUTH_CLIENT_SECRET", "AUTH_GITHUB_SECRET")) then "two live: yes, if an OAuth app"
      elif $k == "GITHUB_APP_PRIVATE_KEY" then "two live: yes, up to 25 keys"
      elif ($k | IN("PGPASSWORD", "POSTGRES_PASSWORD")) or ($v | test("^postgres(ql)?://[^/@:]*:[^/@]+@")) then "hard cut: one password per role"
      elif $k == "RESEND_API_KEY" then "two live: yes"
      elif ($k | IN("POSTMARK_SERVER_TOKEN", "POSTMARK_SERVER_API_TOKEN", "POSTMARK_API_TOKEN", "POSTMARK_API_KEY", "POSTMARK_ACCOUNT_TOKEN", "POSTMARK_ACCOUNT_API_TOKEN")) then "two live: yes"
      elif $k == "TWILIO_AUTH_TOKEN" then "two live: yes, via a secondary Auth Token"
      elif ($k | IN("TWILIO_API_KEY", "TWILIO_API_SECRET", "TWILIO_API_KEY_SECRET")) then "two live: yes"
      elif $k == "SENTRY_AUTH_TOKEN" then "two live: yes"
      elif $k == "SENTRY_DSN" then "two live: yes; Sentry says DSNs are safe to keep public"
      else "" end;
    # AKIA marks a long-term IAM access key (IAM identifiers reference); Railway bucket keys use the
    # same AWS_* names but are not IAM users.
    (any(.[]; .key == "AWS_ACCESS_KEY_ID" and ((.value | tostring) | startswith("AKIA")))) as $iam
  | map(. as $e | ($e.value | tostring) as $v
      | (classify($e.key; $e.value) as $c | $e.key as $k
      | if ($c == "railway_injected") and (($k | test("^RAILWAY_(API_)?TOKEN$")) | not) then empty
        elif ($c | IN("build_tuning", "public_buildtime", "empty")) then empty
        elif $c == "reference" then [9, "References (rotate the source variable, not these)", $k]
        elif ($k | test("(_REGION|_BUCKET|_BUCKET_NAME|_HOST|_HOSTNAME|_PORT|_USER|_USERNAME|_DATABASE|_DB|_CLIENT_ID|_APP_ID|_PROJECT_ID|_ORG_ID|_ENV|^PGUSER|^PGDATABASE|^PGHOST|^PGPORT|^NODE_ENV|^LOG_LEVEL)$"))
             or (($k | test("_URL$")) and (($k | test("WEBHOOK|HOOK")) | not) and ($v | test("^https?://[^@?#]+$")))
          then [0, "config", $k]
        elif ($v | length) < 8 and (($k | test("KEY|SECRET|TOKEN|PASS|DSN|CREDENTIAL|PRIVATE|AUTH|SIGN|SALT|_URL$|_URI$")) | not) then [0, "config", $k]
        elif ($k | test("^(OPENAI|ANTHROPIC|CLAUDE|GROQ|MISTRAL|GEMINI|GOOGLE_GENERATIVE_AI|GOOGLE_AI|COHERE|REPLICATE|TOGETHER|OPENROUTER|HUGGINGFACE|HF|DEEPSEEK|XAI|FIREWORKS|PERPLEXITY|AZURE_OPENAI|VOYAGE|ELEVENLABS|FAL|DEEPGRAM|ASSEMBLYAI|CEREBRAS|LANGSMITH|LANGCHAIN|PINECONE)_")) then [1, "AI provider keys", $k]
        elif $c == "bucket_credential" or ($k | test("^(AWS_|GCP_|GCLOUD_|GOOGLE_APPLICATION_CREDENTIALS|GOOGLE_CLOUD_|GOOGLE_SERVICE_ACCOUNT|AZURE_|CLOUDFLARE_|CF_API|R2_|DIGITALOCEAN_|DO_)")) then [2, "Cloud credentials", $k]
        elif $c == "database" then [3, "Databases and caches", $k]
        elif ($k | test("^(STRIPE|PADDLE|LEMONSQUEEZY|LEMON_SQUEEZY|PAYPAL|BRAINTREE|SQUARE|PLAID|ADYEN|RAZORPAY|POLAR)_")) then [4, "Payments", $k]
        elif ($k | test("^(GITHUB|GH|GITLAB)_.*(TOKEN|PAT)$|^(GITHUB|GH)_PAT|^(NPM_TOKEN|NPM_AUTH|NODE_AUTH_TOKEN|DOCKER|REGISTRY|GHCR|VERCEL_TOKEN|SENTRY_AUTH_TOKEN|NETLIFY_AUTH_TOKEN)|^RAILWAY_(API_)?TOKEN$")) then [5, "Source, registry and deploy tokens", $k]
        elif ($k | test("WEBHOOK")) then [7, "Webhook secrets", $k]
        elif ($k | test("(AUTH|SESSION|JWT|COOKIE|ENCRYPTION|CRYPTO|PAYLOAD|SIGNING|HMAC|CSRF|SALT|PEPPER).*(SECRET|KEY|SALT|PEPPER)|^(PAYLOAD|AUTH|NEXTAUTH|BETTER_AUTH|SESSION|JWT|APP|SECRET_KEY_BASE|DJANGO)_?SECRET")) then [6, "Session, signing and encryption secrets", $k]
        else [8, "Other third-party keys and secrets (review)", $k] end) as $row
      | $row + [if $row[0] >= 1 and $row[0] <= 8 then rotation_hint($e.key; $v; $iam) else "" end])
  | .[] | @tsv'

# Fingerprint exactly what the checklist lists (groups 1-8): config and references are not secrets,
# and fingerprinting them would make put_secrets.sh refuse an unchanged bucket name.
fp_select_jq="$classify_jq"'
  | map(select(.key as $k | $keys | index($k))) | from_entries'

# ---------------------------------------------------------------- projects
if ! railway list --json >"$TMP/projects.json" 2>>"$ERRLOG" || ! jq -e 'type == "array"' "$TMP/projects.json" >/dev/null 2>&1; then
  echo "error: \`railway list --json\` failed or returned an unexpected shape (see $ERRLOG)" >&2
  exit 1
fi

proj_filter='[]'
[ ${#PROJECTS[@]} -gt 0 ] && proj_filter="$(printf '%s\n' "${PROJECTS[@]}" | jq -R . | jq -s -c .)"
env_filter='[]'
[ ${#ENVIRONMENTS[@]} -gt 0 ] && env_filter="$(printf '%s\n' "${ENVIRONMENTS[@]}" | jq -R . | jq -s -c .)"

# project_id<TAB>project_name<TAB>env_name<TAB>service_name, one row per service instance
jq -r --argjson pf "$proj_filter" --argjson ef "$env_filter" '
  .[]
  | select(($pf | length) == 0 or (.id as $i | .name as $n | $pf | index($i) or index($n)))
  | . as $p
  | ([.services.edges[]?.node | {(.id): .name}] | add // {}) as $svc
  | .environments.edges[]?.node
  | select(($ef | length) == 0 or (.name as $n | $ef | index($n)))
  | . as $env
  | ([.serviceInstances.edges[]?.node.serviceId] | map(select(. != null))) as $ids
  | (if ($ids | length) > 0 then $ids else ($svc | keys) end)[]
  | select($svc[.] != null)
  | [$p.id, $p.name, $env.name, $svc[.]] | @tsv' "$TMP/projects.json" >"$TMP/targets.tsv"

n_targets="$(wc -l <"$TMP/targets.tsv" | tr -d ' ')"
[ "$n_targets" -gt 0 ] || { echo "error: no matching project/environment/service found" >&2; exit 1; }
echo "== breach_check: $n_targets service instance(s) to read"

# ---------------------------------------------------------------- per service
last_link=""
i=0
while IFS=$'\t' read -r pid pname ename sname; do
  i=$((i + 1))
  loc="$pname/$ename/$sname"
  work="$TMP/link"
  if [ "$last_link" != "$pid/$ename" ]; then
    rm -rf "$work"; mkdir -p "$work"
    if ! (cd "$work" && railway link --project "$pid" --environment "$ename" </dev/null >/dev/null 2>>"$ERRLOG"); then
      printf '  %-50s FAILED to link (see errors log)\n' "$pname/$ename"
      FAILED=$((FAILED + 1)); last_link=""; continue
    fi
    last_link="$pid/$ename"
  fi

  raw="$TMP/vars.json"
  rc=0
  (cd "$work" && railway variable list -s "$sname" -e "$ename" --json </dev/null >"$raw" 2>>"$ERRLOG") || rc=$?
  if [ "$rc" -ne 0 ] || ! jq -e . "$raw" >/dev/null 2>&1; then
    # older CLIs only have `railway variables`
    rc=0
    (cd "$work" && railway variables -s "$sname" -e "$ename" --json </dev/null >"$raw" 2>>"$ERRLOG") || rc=$?
  fi
  if [ "$rc" -ne 0 ] || ! jq -e . "$raw" >/dev/null 2>&1; then
    printf '  %-50s FAILED to read variables (see errors log)\n' "$loc"
    FAILED=$((FAILED + 1)); rm -f "$raw"; continue
  fi

  jq -r "$group_jq" "$raw" >"$TMP/svc.rows"
  while IFS=$'\t' read -r order group key rhint; do
    printf '%s\t%s\t%s\t%s\t%s\n' "$order" "$group" "$key" "$loc" "$rhint"
  done <"$TMP/svc.rows" >>"$ROWS"

  if [ -n "$FINGERPRINT" ] || [ -n "$VERIFY" ]; then
    keys_json="$(awk -F'\t' '$1 >= 1 && $1 <= 8 { print $3 }' "$TMP/svc.rows" | jq -R . | jq -s -c .)"
    jq --argjson keys "$keys_json" "$fp_select_jq" "$raw" >"$TMP/vars.export.json"
    fp_entries "$TMP/vars.export.json" | while IFS=$'\t' read -r key fp; do
      printf '%s\t%s/%s\n' "$fp" "$loc" "$key"
    done >>"$FP_NEW"
    rm -f "$TMP/vars.export.json"
  fi
  rm -f "$raw"
  printf '  %-50s ok\n' "$loc"
done <"$TMP/targets.tsv"

SKIPPED_CONFIG="$(awk -F'\t' '$1 == 0' "$ROWS" | wc -l | tr -d ' ')"

# ---------------------------------------------------------------- verify
if [ -n "$VERIFY" ]; then
  cut -f1 "$VERIFY" | sort -u >"$TMP/old.hashes"
  while IFS=$'\t' read -r fp where; do
    if grep -qxF "$fp" "$TMP/old.hashes"; then printf '%s\n' "$where"; fi
  done <"$FP_NEW" | sort -u >"$STILL"
fi

# ---------------------------------------------------------------- fingerprint file
if [ -n "$FINGERPRINT" ]; then
  mkdir -p "$(dirname "$FINGERPRINT")"
  gitignore_add_dir "$(dirname "$FINGERPRINT")"
  sort -u "$FP_NEW" >"$FINGERPRINT"
  chmod 600 "$FINGERPRINT" 2>/dev/null || true
fi

# ---------------------------------------------------------------- checklist
hint() {
  case "$1" in
    1) echo "Railway says the attackers were after AI inference providers. Revoke each key at the provider now, then check usage and billing for spend you did not make." ;;
    2) echo "Deactivate and replace. Railway published checks for anomalous [AWS](https://blog.railway.com/p/security-disclosure-recommendation-check-for-anomalous-aws-access) and [GCP](https://blog.railway.com/p/security-disclosure-recommendation-check-for-anomalous-gcp-access) access; review CloudTrail or Cloud Audit Logs for the old key." ;;
    3) echo "Change the password (\`ALTER ROLE ... PASSWORD\`) and update every variable that references it. If the database had a public TCP proxy it was reachable from the internet: review roles, connections and recent schema changes." ;;
    4) echo "Roll the keys in the provider dashboard and review recent events, payouts and webhook endpoints for changes you did not make." ;;
    5) echo "Revoke and reissue, then read the account's security or audit log. Leaked registry credentials mean existing image tags can't be trusted: rebuild from source." ;;
    6) echo "Anyone holding these can forge sessions or signatures. Rotating logs users out. If the library also encrypts stored data with it (Payload, Better Auth), re-encrypt that data (with the library's rotation tooling where it has one; Payload 3 has none), then remove the old value: keeping it as an accepted 'previous' secret keeps forged tokens valid." ;;
    7) echo "Roll the signing secret at the sender. Until then, anyone can forge webhook events your app will accept." ;;
    8) echo "Rotate at each provider. Some of these may be plain config; skip the ones that are not secrets." ;;
    9) echo "These point at another variable (\`\${{Service.VAR}}\`). Rotate the source variable; these follow automatically." ;;
  esac
}

total="$(awk -F'\t' '$1 > 0 && $1 < 9' "$ROWS" | wc -l | tr -d ' ')"
{
  echo "# Railway exposure checklist"
  echo
  echo "Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by \`breach_check.sh\`. Names only: no value appears in this file."
  echo "Context: Railway's [security disclosure of 2026-10-21](https://blog.railway.com/p/security-disclosure-wednesday-october-21st)"
  echo "recommends rolling every environment variable. This file lists what that means for your account."
  echo
  echo "- Variables to rotate: **$total** across $n_targets service instance(s)"
  echo "- Short config-looking values left out: $SKIPPED_CONFIG"
  [ "$FAILED" -gt 0 ] && echo "- **Could not read: $FAILED** (see \`$ERRLOG\`). Those services are NOT covered below."
  if [ -n "$VERIFY" ]; then
    echo "- Still holding an exposed value (from \`$VERIFY\`): **$(wc -l <"$STILL" | tr -d ' ')**"
  fi
  echo
  echo "Rotate in the order below. For keys a provider lets you run side by side (two active keys),"
  echo "create the new one, deploy it, then revoke the old one. Note that Railway paused deployments"
  echo "during the incident: if you can't deploy, revoking first takes the service down."
  echo
  if awk -F'\t' '$1 >= 1 && $1 <= 8 && $5 != "" { found = 1 } END { exit !found }' "$ROWS"; then
    echo "A note in brackets after a name says whether that provider lets the old and new credential"
    echo "work at the same time: \`two live: yes\` (deploy the new one, then revoke), \`two live: grace\` (the"
    echo "old one keeps working for a limited window after you roll it), \`hard cut\` (one credential: change"
    echo "it and redeploy together). Source and steps: derail's \`references/breach-response.md\` section 4."
    echo "No note means the provider is not in that table: check the provider's docs."
    echo
  fi
  if [ -n "$VERIFY" ] && [ -s "$STILL" ]; then
    echo "## Not rotated yet"
    echo
    echo "These still hold a value that was fingerprinted before rotation:"
    echo
    sed 's/^/- [ ] `/; s/$/`/' "$STILL"
    echo
  fi
  for order in 1 2 3 4 5 6 7 8 9; do
    rows="$(awk -F'\t' -v o="$order" '$1 == o' "$ROWS" | sort -t$'\t' -k3,3 -k4,4)"
    [ -n "$rows" ] || continue
    group="$(printf '%s\n' "${rows%%$'\n'*}" | cut -f2)"
    echo "## $order. $group"
    echo
    hint "$order"
    echo
    printf '%s\n' "$rows" | awk -F'\t' '
      { id = $3 SUBSEP $5
        if (!(id in where)) { ids[++n] = id; name[id] = $3; note[id] = $5; where[id] = $4 } else { where[id] = where[id] ", " $4 } }
      END { for (i = 1; i <= n; i++) { id = ids[i]
              printf "- [ ] `%s` (%s)%s\n", name[id], where[id], (note[id] == "" ? "" : " [" note[id] "]") } }'
    echo
  done
  echo "## Not covered by this script"
  echo
  echo "- **Sealed variables.** The CLI cannot read them, so they are missing above. Open each service in the"
  echo "  Railway dashboard, find the sealed ones, and rotate them at their provider."
  echo "- **Railway account and project tokens** you created for CI. Revoke them in Railway's account settings and"
  echo "  update the CI secret store that holds them."
  echo "- **Copies elsewhere.** The same key in GitHub Actions secrets, a laptop \`.env\`, or another host is the"
  echo "  same key. Rotating means every copy."
  if [ -n "$FINGERPRINT" ]; then
    echo
    echo "Fingerprints of the current values were written to \`$FINGERPRINT\`. After rotating, run"
    echo "\`breach_check.sh --verify $FINGERPRINT\` to prove nothing exposed is still in use."
  fi
} >"$OUT"

[ -s "$ERRLOG" ] || rm -f "$ERRLOG"
echo "checklist: $OUT ($total variables to rotate, $FAILED unreadable)"
[ -n "$FINGERPRINT" ] && echo "fingerprints: $FINGERPRINT ($(wc -l <"$FINGERPRINT" | tr -d ' ') values, mode 600; keep it out of git)"
if [ -n "$VERIFY" ]; then
  still="$(wc -l <"$STILL" | tr -d ' ')"
  if [ "$still" -gt 0 ]; then
    echo "verify: $still variable(s) still hold an exposed value (listed in $OUT)"
    exit 1
  fi
  if [ "$FAILED" -gt 0 ]; then
    echo "verify: incomplete, $FAILED service(s) could not be read (see $ERRLOG); fix that and re-run"
    exit 3
  fi
  echo "verify: no variable holds a fingerprinted value"
fi
exit 0
