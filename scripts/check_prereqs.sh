#!/usr/bin/env bash
# check_prereqs.sh - verify the local toolchain for a Railway/Vercel -> AWS migration.
#
# Prints a pass/fail table. Exits non-zero only on HARD failures (terraform/tofu, aws CLI,
# aws credentials, jq). Everything else is a warning. With --no-aws / --offline the AWS checks are
# skipped and missing CLIs become warnings; terraform/tofu stays the only hard failure.
#
# Secret-handling rule: this script never prints credentials. `aws sts get-caller-identity`
# output is reduced to account id + region only.
set -euo pipefail

PG_MAJOR_WANTED=""
WANT_RAILWAY=1
WANT_VERCEL=1
WANT_AWS=1
OFFLINE=0
TF_MIN="1.11"

usage() {
  cat <<'EOF'
Usage: check_prereqs.sh [--pg-major N] [--no-aws] [--no-railway] [--no-vercel] [--offline] [--help]

Checks:
  terraform (>= 1.11) or tofu        HARD (always)
  aws CLI v2 + sts get-caller-identity   HARD (prints account id + region only; skipped by --no-aws)
  jq                                 HARD (WARN with --no-aws / --offline)
  docker + buildx                    warn
  pg_dump / pg_restore / psql        warn (warn if major < --pg-major)
  railway CLI (>= 5.27.0) + whoami   warn (skip with --no-railway)
  vercel  CLI + `vercel whoami`      warn (skip with --no-vercel)
  node (>= 20), git                  warn

Options:
  --pg-major N    source Postgres major version (e.g. 18). pg_dump must be >= N.
  --no-aws        skip the AWS CLI and credential checks (planning on a machine without AWS access)
  --no-railway    do not check the Railway CLI
  --no-vercel     do not check the Vercel CLI
  --offline       = --no-aws --no-railway --no-vercel: no network calls, no logins. Only terraform/tofu
                  can fail hard; every other missing tool is reported as WARN.
  -h, --help      show this help

Exit codes: 0 = all hard checks passed (warnings may exist), 1 = hard failure, 2 = usage error.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pg-major) PG_MAJOR_WANTED="${2:-}"; shift 2 ;;
    --pg-major=*) PG_MAJOR_WANTED="${1#*=}"; shift ;;
    --no-aws) WANT_AWS=0; shift ;;
    --no-railway) WANT_RAILWAY=0; shift ;;
    --no-vercel) WANT_VERCEL=0; shift ;;
    --offline) OFFLINE=1; WANT_AWS=0; WANT_RAILWAY=0; WANT_VERCEL=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

HARD_FAIL=0
WARN=0
ROWS=()

# row <status> <name> <detail>   status: PASS | WARN | FAIL | SKIP
row() {
  local status="$1" name="$2" detail="${3:-}"
  ROWS+=("$(printf '%s|%s|%s' "$status" "$name" "$detail")")
  case "$status" in
    FAIL) HARD_FAIL=1 ;;
    WARN) WARN=1 ;;
  esac
}

have() { command -v "$1" >/dev/null 2>&1; }

# version_ge A B -> 0 if A >= B (dotted numeric compare)
version_ge() {
  local a="$1" b="$2"
  [ "$(printf '%s\n%s\n' "$b" "$a" | sort -V | head -n1)" = "$b" ]
}

# ---- terraform / tofu ---------------------------------------------------
if have terraform; then
  tf_ver="$(terraform version -json 2>/dev/null | jq -r '.terraform_version // empty' 2>/dev/null || true)"
  if [ -z "$tf_ver" ]; then
    tf_ver="$(terraform version 2>/dev/null | head -n1 | sed -E 's/^Terraform v?//' || true)"
  fi
  if [ -n "$tf_ver" ] && version_ge "$tf_ver" "$TF_MIN"; then
    row PASS "terraform" "v$tf_ver (>= $TF_MIN)"
  else
    row FAIL "terraform" "v${tf_ver:-unknown} < $TF_MIN (write-only secret args need >= 1.11)"
  fi
elif have tofu; then
  tofu_ver="$(tofu version 2>/dev/null | head -n1 | sed -E 's/^OpenTofu v?//' || true)"
  row PASS "tofu" "v${tofu_ver:-unknown} (terraform not found; OpenTofu accepted)"
else
  row FAIL "terraform" "not installed (need terraform >= $TF_MIN or tofu)"
fi

# ---- aws CLI -----------------------------------------------------------
if [ "$WANT_AWS" -eq 0 ]; then
  if have aws; then
    row SKIP "aws CLI" "present; credential check skipped (--no-aws/--offline)"
  else
    row WARN "aws CLI" "not installed (needed later for terraform apply, ECR push, put_secrets.sh)"
  fi
elif have aws; then
  aws_ver_raw="$(aws --version 2>&1 | head -n1 || true)"
  aws_ver="$(printf '%s' "$aws_ver_raw" | sed -nE 's#^aws-cli/([0-9]+(\.[0-9]+)*).*#\1#p')"
  if [ -n "$aws_ver" ] && version_ge "$aws_ver" "2.0.0"; then
    row PASS "aws CLI" "v$aws_ver"
  else
    row FAIL "aws CLI" "v${aws_ver:-unknown} (need v2)"
  fi
  # Identity: print ONLY account id and region. Never the ARN (may contain a user name) or keys.
  if ident_json="$(aws sts get-caller-identity --output json 2>/dev/null)"; then
    acct="$(printf '%s' "$ident_json" | jq -r '.Account // "unknown"')"
    region="$(aws configure get region 2>/dev/null || true)"
    region="${AWS_REGION:-${AWS_DEFAULT_REGION:-${region:-unset}}}"
    row PASS "aws credentials" "account=$acct region=$region"
  else
    row FAIL "aws credentials" "sts get-caller-identity failed (run: aws login / aws sso login / set AWS_PROFILE)"
  fi
else
  row FAIL "aws CLI" "not installed (https://docs.aws.amazon.com/cli/)"
fi

# ---- docker + buildx ---------------------------------------------------
if have docker; then
  d_ver="$(docker --version 2>/dev/null | head -n1 | sed -nE 's/^Docker version ([^,]+).*/\1/p' || true)"
  if docker buildx version >/dev/null 2>&1; then
    bx="$(docker buildx version 2>/dev/null | head -n1 | awk '{print $2}')"
    row PASS "docker + buildx" "docker ${d_ver:-?}, buildx ${bx:-?}"
  else
    row WARN "docker + buildx" "docker ${d_ver:-?} found but buildx missing (needed for --platform linux/arm64)"
  fi
  if ! docker info >/dev/null 2>&1; then
    row WARN "docker daemon" "not reachable (start Docker Desktop / dockerd before building images)"
  fi
else
  row WARN "docker + buildx" "not installed (needed to build and push images to ECR)"
fi

# ---- postgres client tools --------------------------------------------
pg_major_of() { "$1" --version 2>/dev/null | sed -nE 's/.* ([0-9]+)(\.[0-9]+)?.*/\1/p' | head -n1; }
for tool in pg_dump pg_restore psql; do
  if have "$tool"; then
    maj="$(pg_major_of "$tool")"
    full="$("$tool" --version 2>/dev/null | head -n1 | sed -E 's/^[^0-9]*//')"
    if [ -n "$PG_MAJOR_WANTED" ] && [ -n "$maj" ] && [ "$maj" -lt "$PG_MAJOR_WANTED" ]; then
      row WARN "$tool" "v$full < source major $PG_MAJOR_WANTED (install PGDG postgresql-client-$PG_MAJOR_WANTED)"
    else
      row PASS "$tool" "v${full:-?}"
    fi
  else
    row WARN "$tool" "not installed (needed for pg_migrate.sh)"
  fi
done

# ---- railway CLI -------------------------------------------------------
# Minimum versions, from the CLI release notes: tcp-proxy in v5.15.0, connect --tunnel-only in v5.27.0.
RAILWAY_MIN="5.27.0"
RAILWAY_TCP_PROXY_MIN="5.15.0"
if [ "$WANT_RAILWAY" -eq 1 ]; then
  if have railway; then
    # `railway --version` prints e.g. "railway 4.16.1". The raw line is untrusted: keep printable
    # characters only, drop the table separator, cap the length.
    r_raw="$(railway --version 2>/dev/null | head -n1 | LC_ALL=C tr -cd '[:print:]' | tr -d '|' | cut -c1-80 || true)"
    r_ver="$(printf '%s\n' "$r_raw" | sed -nE 's/^[^0-9]*([0-9]{1,6}\.[0-9]{1,6}(\.[0-9]{1,6})?)([^0-9].*)?$/\1/p' | head -n1)"
    if [ -z "$r_ver" ]; then
      row WARN "railway version" "unrecognized version output '${r_raw:-<empty>}'; need >= $RAILWAY_MIN for railway connect --tunnel-only"
    elif ! version_ge "$r_ver" "$RAILWAY_MIN"; then
      missing="railway connect --tunnel-only (>= $RAILWAY_MIN)"
      if ! version_ge "$r_ver" "$RAILWAY_TCP_PROXY_MIN"; then
        missing="$missing, railway tcp-proxy (>= $RAILWAY_TCP_PROXY_MIN)"
      fi
      if [ "${r_ver%%.*}" -lt 5 ]; then
        missing="$missing, the 5.x subcommands railway_inventory.sh uses (variable, bucket, config, postgres, usage, cron)"
      fi
      row WARN "railway version" "v$r_ver < $RAILWAY_MIN: missing $missing. Upgrade: brew upgrade railway | npm update -g @railway/cli"
    fi
    if railway whoami >/dev/null 2>&1; then
      row PASS "railway CLI" "v${r_ver:-?}, logged in"
    else
      row WARN "railway CLI" "v${r_ver:-?}, not logged in (railway login --browserless or RAILWAY_API_TOKEN)"
    fi
  else
    row WARN "railway CLI" "not installed (npm i -g @railway/cli | brew install railway)"
  fi
fi

# ---- vercel CLI --------------------------------------------------------
if [ "$WANT_VERCEL" -eq 1 ]; then
  if have vercel; then
    v_ver="$(vercel --version 2>/dev/null | head -n1 | sed -E 's/^[^0-9]*//' || true)"
    if vercel whoami >/dev/null 2>&1; then
      row PASS "vercel CLI" "v${v_ver:-?}, logged in"
    else
      row WARN "vercel CLI" "v${v_ver:-?}, not logged in (vercel login or VERCEL_TOKEN)"
    fi
  else
    row WARN "vercel CLI" "not installed (npm i -g vercel)"
  fi
fi

# ---- node / jq / git ---------------------------------------------------
if have node; then
  n_ver="$(node --version 2>/dev/null | sed 's/^v//')"
  if version_ge "$n_ver" "20.0.0"; then
    row PASS "node" "v$n_ver"
  else
    row WARN "node" "v$n_ver < 20 (blob_to_s3.ts needs Node 20+)"
  fi
else
  row WARN "node" "not installed (needed for blob_to_s3.ts and the Vercel CLI)"
fi

if have jq; then
  row PASS "jq" "$(jq --version 2>/dev/null)"
elif [ "$WANT_AWS" -eq 0 ]; then
  # offline / planning mode: only terraform may fail hard
  row WARN "jq" "not installed (apt install jq | brew install jq); inventory + put_secrets scripts need it"
else
  # jq is used by several scripts; treat as hard since inventory scripts depend on it.
  row FAIL "jq" "not installed (apt install jq | brew install jq)"
fi

if have git; then
  row PASS "git" "$(git --version 2>/dev/null | awk '{print $3}')"
else
  row WARN "git" "not installed"
fi

# ---- print table -------------------------------------------------------
[ "$OFFLINE" -eq 1 ] && echo "(offline mode: no AWS/Railway/Vercel calls; only terraform/tofu can fail hard)"
printf '\n%-6s %-18s %s\n' "STATUS" "CHECK" "DETAIL"
printf '%-6s %-18s %s\n' "------" "------------------" "------"
for r in "${ROWS[@]}"; do
  IFS='|' read -r s n d <<<"$r"
  printf '%-6s %-18s %s\n' "$s" "$n" "$d"
done
echo

if [ "$HARD_FAIL" -eq 1 ]; then
  echo "RESULT: FAIL - fix the FAIL rows above before continuing." >&2
  exit 1
elif [ "$WARN" -eq 1 ]; then
  echo "RESULT: OK with warnings - review WARN rows (some steps will be unavailable)."
  exit 0
else
  echo "RESULT: OK - all checks passed."
  exit 0
fi
