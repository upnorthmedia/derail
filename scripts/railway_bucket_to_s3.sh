#!/usr/bin/env bash
# railway_bucket_to_s3.sh - copy a Railway Bucket (S3-compatible, Tigris-backed) into an S3 bucket.
#
# Two steps, both `aws s3 sync` (idempotent, resumable):
#   1. Railway bucket  -> local staging dir   (credentials from `railway bucket credentials -b <name>`,
#                                              loaded with eval into THIS process only; never printed)
#   2. local staging   -> s3://<target>        (your normal AWS credential chain)
#
# Why two steps: the Railway credentials and your AWS credentials are different principals; a direct
# server-side copy is impossible across providers, and keeping two credential sets in one `aws`
# invocation is error-prone. For buckets larger than local disk, use rclone instead (see --help).
set -euo pipefail

BUCKET=""
TARGET=""
STAGING="migration/bucket-staging"
DRY_RUN=0
DELETE=0
EXTRA_SYNC_ARGS=()

usage() {
  cat <<'EOF'
Usage: railway_bucket_to_s3.sh --bucket <railway-bucket-name> --target s3://<bucket>[/prefix]
                               [--staging migration/bucket-staging] [--delete] [--dry-run]
                               [-- <extra aws s3 sync args, e.g. --exclude 'tmp/*'>]

Requires: railway CLI (linked to the project/environment that owns the bucket), aws CLI v2.

Steps:
  1. eval "$(railway bucket credentials -b <name>)"   -> AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY /
     AWS_ENDPOINT_URL / AWS_S3_BUCKET_NAME / AWS_REGION(auto) exported into this shell only
  2. aws s3 sync s3://$AWS_S3_BUCKET_NAME <staging> --endpoint-url "$AWS_ENDPOINT_URL"
  3. unset the Railway credentials, then aws s3 sync <staging> <target> with your AWS identity

Notes:
  - Railway Buckets have no versioning/lifecycle/SSE, so a plain object copy is complete.
  - Content-Type is preserved by `aws s3 sync` (it uploads with the local file's guessed type; pass
    --content-type overrides via extra args if your objects are extensionless).
  - --delete propagates deletions from Railway to the target (use only on the final sync).
  - Large buckets (> free local disk): use rclone with two remotes instead of staging:
        rclone config create railway s3 provider=Other endpoint="$AWS_ENDPOINT_URL" \
          access_key_id=... secret_access_key=... region=auto    # values from `railway bucket credentials`
        rclone sync railway:$AWS_S3_BUCKET_NAME s3-target:bucket/prefix --transfers 32 --checksum
  - After cutover: drop the bucket's static keys from the app; use the ECS task role for S3.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bucket|-b) BUCKET="${2:-}"; shift 2 ;;
    --bucket=*) BUCKET="${1#*=}"; shift ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --target=*) TARGET="${1#*=}"; shift ;;
    --staging) STAGING="${2:-}"; shift 2 ;;
    --staging=*) STAGING="${1#*=}"; shift ;;
    --delete) DELETE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; EXTRA_SYNC_ARGS=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$BUCKET" ] || { echo "error: --bucket is required" >&2; usage >&2; exit 2; }
[ -n "$TARGET" ] || { echo "error: --target s3://... is required" >&2; usage >&2; exit 2; }
case "$TARGET" in s3://*) ;; *) echo "error: --target must start with s3://" >&2; exit 2 ;; esac
command -v railway >/dev/null 2>&1 || { echo "error: railway CLI not found (npm i -g @railway/cli)" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "error: aws CLI not found" >&2; exit 1; }

mkdir -p "$STAGING"
SYNC_FLAGS=(--only-show-errors --no-progress)
[ "$DRY_RUN" -eq 1 ] && SYNC_FLAGS+=(--dryrun)
[ "$DELETE" -eq 1 ] && SYNC_FLAGS+=(--delete)

echo "== Railway bucket '$BUCKET' -> $STAGING -> $TARGET  (dry-run: $DRY_RUN)"

# ---- step 1: Railway credentials -> this process only
# `railway bucket credentials` prints `export AWS_...=...` lines. We eval them in a subshell-scoped
# block and unset them afterwards. They are never echoed.
creds="$(railway bucket credentials -b "$BUCKET" 2>/dev/null)" || { echo "error: 'railway bucket credentials -b $BUCKET' failed (is the project linked? does the bucket exist in this environment?)" >&2; exit 1; }
if ! printf '%s' "$creds" | grep -q 'AWS_SECRET_ACCESS_KEY'; then
  echo "error: unexpected output from 'railway bucket credentials' (no AWS_SECRET_ACCESS_KEY line). Run it manually to inspect; do not paste the output anywhere." >&2
  exit 1
fi

(
  # subshell: Railway identity lives and dies here
  # shellcheck disable=SC2046
  eval "$(printf '%s\n' "$creds" | grep -E '^(export )?AWS_[A-Z_]+=')"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-https://t3.storageapi.dev}"
  export AWS_REGION="${AWS_REGION:-auto}"
  export AWS_DEFAULT_REGION="$AWS_REGION"
  export AWS_S3_BUCKET_NAME="${AWS_S3_BUCKET_NAME:-${BUCKET}}"
  unset AWS_PROFILE AWS_SESSION_TOKEN   # make sure the local AWS identity is not mixed in
  echo "-- step 1/2: Railway s3://$AWS_S3_BUCKET_NAME (endpoint $AWS_ENDPOINT_URL) -> $STAGING"
  count="$(aws s3 ls "s3://$AWS_S3_BUCKET_NAME" --recursive --endpoint-url "$AWS_ENDPOINT_URL" --summarize 2>/dev/null | sed -nE 's/^ *Total Objects: ([0-9]+)/\1/p' || true)"
  size="$(aws s3 ls "s3://$AWS_S3_BUCKET_NAME" --recursive --endpoint-url "$AWS_ENDPOINT_URL" --summarize 2>/dev/null | sed -nE 's/^ *Total Size: ([0-9]+)/\1/p' || true)"
  echo "   objects: ${count:-?}  bytes: ${size:-?}"
  aws s3 sync "s3://$AWS_S3_BUCKET_NAME" "$STAGING" --endpoint-url "$AWS_ENDPOINT_URL" "${SYNC_FLAGS[@]}" "${EXTRA_SYNC_ARGS[@]}"
)
unset creds

# ---- step 2: local -> S3 with the normal AWS identity
echo "-- step 2/2: $STAGING -> $TARGET (AWS identity: account $(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '?'))"
aws s3 sync "$STAGING" "$TARGET" "${SYNC_FLAGS[@]}" "${EXTRA_SYNC_ARGS[@]}"

local_count="$(find "$STAGING" -type f | wc -l | tr -d ' ')"
if [ "$DRY_RUN" -eq 0 ]; then
  remote_count="$(aws s3 ls "$TARGET/" --recursive --summarize 2>/dev/null | sed -nE 's/^ *Total Objects: ([0-9]+)/\1/p' || echo '?')"
  echo "done: staged files=$local_count  objects under $TARGET=$remote_count"
  echo "Re-run before cutover to pick up new objects (sync is incremental). Delete $STAGING when the migration is final."
else
  echo "dry-run complete (staged files currently: $local_count)"
fi
