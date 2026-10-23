#!/usr/bin/env bash
# shellcheck disable=SC2034  # rc and FIXTURE_VALUES are read by check() through eval
# Tests for the per-variable rotation hints in breach_check.sh ("two live: ...", "hard cut: ...").
#
# Hints come only from the provider table in references/breach-response.md section 4. These tests pin
# which names get which hint, that unknown or look-alike names get none, and that hints never leak a
# value or change the fingerprint and --verify output. Runs against a stand-in `railway` CLI on PATH.
#
#   bash scripts/tests/test_breach_hints.sh            # uses `bash` from PATH
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
# Pipe into `grep >/dev/null`, not `grep -q`: -q exits early and, with pipefail, SIGPIPE flakes.
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# ---------------------------------------------------------------- fake railway CLI
mkdir -p "$T/bin" "$T/fixture/vars"
cat >"$T/bin/railway" <<'EOF'
#!/usr/bin/env bash
set -eu
D="$FAKE_RAILWAY_DIR"
svc=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[$i]}" = "-s" ] && svc="${args[$((i + 1))]}"; done
case "${1:-} ${2:-}" in
  "whoami "*) echo "Logged in as Test" ;;
  "list --json") cat "$D/projects.json" ;;
  "link "*) : ;;
  "variable list"|"variables "*) cat "$D/vars/$svc.json" ;;
  *) echo "fake railway: unhandled: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$T/bin/railway"
export FAKE_RAILWAY_DIR="$T/fixture"
export PATH="$T/bin:$PATH"

cat >"$T/fixture/projects.json" <<'EOF'
[{"id":"p1","name":"shop","environments":{"edges":[{"node":{"id":"e1","name":"production","serviceInstances":{"edges":[
   {"node":{"serviceId":"s1"}},{"node":{"serviceId":"s2"}},{"node":{"serviceId":"s3"}},{"node":{"serviceId":"s4"}}]}}}]},
  "services":{"edges":[{"node":{"id":"s1","name":"web"}},{"node":{"id":"s2","name":"Postgres"}},
                       {"node":{"id":"s3","name":"worker"}},{"node":{"id":"s4","name":"uploads"}}]}}]
EOF
# Values are fixtures shaped like the real thing only where a hint depends on the shape.
cat >"$T/fixture/vars/web.json" <<'EOF'
{"OPENAI_API_KEY":"sk-proj-FIXTUREopenai0000000000001","ANTHROPIC_API_KEY":"sk-ant-FIXTUREanthropic000000001",
 "GROQ_API_KEY":"gsk_FIXTUREgroq00000000000001",
 "STRIPE_SECRET_KEY":"sk_live_FIXTUREstripe000000001","STRIPE_WEBHOOK_SECRET":"whsec_FIXTUREwebhook00000001",
 "STRIPE_LEGACY_SECRET":"FIXTUREnotastripekey000000001",
 "GITHUB_TOKEN":"ghp_FIXTUREgithub00000000000001","GITHUB_CLIENT_SECRET":"FIXTUREghoauth000000000001",
 "GITHUB_APP_PRIVATE_KEY":"FIXTUREghappkey000000000000001",
 "RESEND_API_KEY":"re_FIXTUREresend0000000000001","POSTMARK_SERVER_TOKEN":"FIXTUREpostmark00000000000001",
 "TWILIO_AUTH_TOKEN":"FIXTUREtwilioauth0000000000001","TWILIO_API_SECRET":"FIXTUREtwilioapi00000000000001",
 "SENTRY_AUTH_TOKEN":"sntrys_FIXTUREsentry000000000001","SENTRY_DSN":"https://FIXTUREdsnkey0001@o1.ingest.sentry.io/1",
 "MAILGUN_API_KEY":"FIXTUREmailgun00000000000001","BETTER_AUTH_SECRET":"FIXTUREauthsecret0000000000000001",
 "OPENAI_API_KEY_OLD":"sk-proj-FIXTUREopenaiold00000000001",
 "GCP_SERVICE_ACCOUNT_KEY":"{\"type\":\"service_account\",\"private_key\":\"FIXTUREgcpkey000000001\"}",
 "GOOGLE_APPLICATION_CREDENTIALS":"/app/FIXTURE-credentials.json",
 "DATABASE_URL":"${{Postgres.DATABASE_URL}}","REDIS_URL":"redis://default:FIXTUREredis0000001@redis.railway.internal:6379"}
EOF
cat >"$T/fixture/vars/Postgres.json" <<'EOF'
{"DATABASE_URL":"postgresql://postgres:FIXTUREpgpass000000001@postgres.railway.internal:5432/railway",
 "PGPASSWORD":"FIXTUREpgpass000000001","POSTGRES_PASSWORD":"FIXTUREpgpass000000001","PGUSER":"postgres"}
EOF
# worker: a real IAM access key (AKIA prefix). uploads: a Railway bucket's S3-style keys, which are not IAM.
cat >"$T/fixture/vars/worker.json" <<'EOF'
{"AWS_ACCESS_KEY_ID":"AKIAFIXTURE000000001","AWS_SECRET_ACCESS_KEY":"FIXTUREawssecret00000000000000001"}
EOF
cat >"$T/fixture/vars/uploads.json" <<'EOF'
{"AWS_ACCESS_KEY_ID":"FIXTUREbucketkeyid000000001","AWS_SECRET_ACCESS_KEY":"FIXTUREbucketsecret0000000000001",
 "AWS_ENDPOINT_URL":"https://FIXTURE.storageapi.dev","AWS_S3_BUCKET_NAME":"uploads-FIXTURE"}
EOF
FIXTURE_VALUES="FIXTURE|sk-proj-|sk-ant-|sk_live_|whsec_|ghp_|AKIA|sntrys_|re_FIX"

cd "$T"
# line_for KEY: the checklist line(s) for that variable name.
line_for() { grep -F -- "- [ ] \`$1\`" exposure.md || true; }
# has_hint KEY HINT [LOCATION]: a checklist line for KEY carries exactly [HINT] (and names LOCATION).
has_hint() { line_for "$1" | grep -F -- "${3:-}" | grep -F -- "[$2]" >/dev/null; }
no_hint() { [ -n "$(line_for "$1")" ] && ! line_for "$1" | grep -E -- '\[(two live|hard cut):' >/dev/null; }

echo "== breach_check.sh rotation hints"
rc=0; "$SH" "$SCRIPTS/breach_check.sh" --out exposure.md --fingerprint secrets/railway.burned.sha256 >stdout.txt 2>stderr.txt || rc=$?
check "exits 0" '[ "$rc" -eq 0 ]'

check "OpenAI key: two live" 'has_hint OPENAI_API_KEY "two live: yes"'
check "Anthropic key: two live, revoke at once" 'has_hint ANTHROPIC_API_KEY "two live: yes; Anthropic advises revoking at once"'
check "Stripe secret key: 7-day grace" 'has_hint STRIPE_SECRET_KEY "two live: grace, up to 7 days"'
check "Stripe webhook secret: 24-hour grace" 'has_hint STRIPE_WEBHOOK_SECRET "two live: grace, up to 24 hours"'
check "GitHub token: two live if a PAT" 'has_hint GITHUB_TOKEN "two live: yes, if a personal access token"'
check "GitHub OAuth client secret: two live if an OAuth app" 'has_hint GITHUB_CLIENT_SECRET "two live: yes, if an OAuth app"'
check "GitHub App private key: up to 25" 'has_hint GITHUB_APP_PRIVATE_KEY "two live: yes, up to 25 keys"'
check "Resend key: two live" 'has_hint RESEND_API_KEY "two live: yes"'
check "Postmark token: two live" 'has_hint POSTMARK_SERVER_TOKEN "two live: yes"'
check "Twilio Auth Token: via secondary" 'has_hint TWILIO_AUTH_TOKEN "two live: yes, via a secondary Auth Token"'
check "Twilio API key secret: two live" 'has_hint TWILIO_API_SECRET "two live: yes"'
check "Sentry auth token: two live" 'has_hint SENTRY_AUTH_TOKEN "two live: yes"'
check "Sentry DSN: public by design" 'has_hint SENTRY_DSN "two live: yes; Sentry says DSNs are safe to keep public"'
check "GCP service account key JSON: up to 10" 'has_hint GCP_SERVICE_ACCOUNT_KEY "two live: yes, up to 10 keys per service account"'
check "IAM access key: two per user" 'has_hint AWS_ACCESS_KEY_ID "two live: yes, 2 keys per IAM user" shop/production/worker'
check "IAM secret key follows its key id" 'has_hint AWS_SECRET_ACCESS_KEY "two live: yes, 2 keys per IAM user" shop/production/worker'
check "Railway bucket keys are not IAM: no hint" '! line_for AWS_ACCESS_KEY_ID | grep -F "uploads" | grep -F "[two live" >/dev/null && line_for AWS_ACCESS_KEY_ID | grep -F "uploads" >/dev/null'
check "Postgres password: hard cut" 'has_hint PGPASSWORD "hard cut: one password per role"'
check "POSTGRES_PASSWORD: hard cut" 'has_hint POSTGRES_PASSWORD "hard cut: one password per role"'
check "Postgres URL with a password: hard cut" 'has_hint DATABASE_URL "hard cut: one password per role" shop/production/Postgres'

check "unknown AI provider gets no hint" 'no_hint GROQ_API_KEY'
check "unknown email provider gets no hint" 'no_hint MAILGUN_API_KEY'
check "session secret gets no hint" 'no_hint BETTER_AUTH_SECRET'
check "look-alike name gets no hint" 'no_hint OPENAI_API_KEY_OLD'
check "Stripe-named value without a Stripe key shape gets no hint" 'no_hint STRIPE_LEGACY_SECRET'
check "credentials file path gets no hint" 'no_hint GOOGLE_APPLICATION_CREDENTIALS'
check "Redis URL gets no hint" 'no_hint REDIS_URL'
check "reference gets no hint" '! line_for DATABASE_URL | grep -F "shop/production/web" | grep -E "\[(two live|hard cut)" >/dev/null'
check "legend points to section 4" 'grep -F "references/breach-response.md" exposure.md | grep -F "section 4" >/dev/null'
check "no value in checklist, stdout, stderr or fingerprints" '! grep -Eq "$FIXTURE_VALUES" exposure.md stdout.txt stderr.txt secrets/railway.burned.sha256'
check "fingerprint lines are fingerprint<TAB>location/KEY only" '! grep -E "two live|hard cut" secrets/railway.burned.sha256 >/dev/null && awk -F"\t" "NF != 2 { bad = 1 } END { exit bad }" secrets/railway.burned.sha256'

rc=0; "$SH" "$SCRIPTS/breach_check.sh" --out v1.md --verify secrets/railway.burned.sha256 >verify1.txt 2>&1 || rc=$?
check "verify before rotation exits 1" '[ "$rc" -eq 1 ]'
check "verify list stays location/KEY with no hint" 'awk "/^## Not rotated yet/,/^## 1\\./" v1.md | grep -F -- "- [ ] \`shop/production/web/OPENAI_API_KEY\`" >/dev/null && ! awk "/^## Not rotated yet/,/^## 1\\./" v1.md | grep -E "two live|hard cut" >/dev/null'

echo
echo "passed: $PASS  failed: $FAIL  (shell: $("$SH" -c 'echo $BASH_VERSION'))"
[ "$FAIL" -eq 0 ]
