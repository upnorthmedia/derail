#!/usr/bin/env bash
# railway_volume_to_s3.sh - copy the contents of a Railway VOLUME (block storage mounted into a
# service, e.g. /data uploads) into an S3 prefix, via a local staging directory.
#
#   Railway volume (inside the service container)  --(1)-->  local staging dir  --(2)-->  s3://bucket/prefix
#
# Step 1 has two methods because Railway volumes are not reachable over any object API:
#   files  (default)  railway volume files download <mount-path> <staging>   (newer Railway CLI, >= 4.x;
#                     streams the directory out of the running service's volume)
#   scp               scp -r <service>@ssh.railway.com:<mount-path> <staging>   (works wherever `railway ssh`
#                     works for the service: the service must be running, your SSH key must be linked to
#                     your Railway account, and the project/environment must be linked in this directory)
# Step 2 is `aws s3 sync` with your normal AWS identity. Both steps are incremental, so the script can
# be run repeatedly (first bulk copy days ahead, final delta during the cutover freeze).
#
# Content types: `aws s3 sync` sets Content-Type from the file extension (mimetypes). Extensionless
# files become binary/octet-stream; pass `-- --content-type <type>` for a homogeneous tree, or fix
# afterwards with `aws s3 cp s3://... s3://... --recursive --metadata-directive REPLACE --content-type ...`.
# A manifest (path, size, sha256, guessed content type) is written next to the staging dir so the
# application's DB rows (file paths) can be rewritten to S3 keys/URLs.
#
# Nothing secret is printed: no Railway tokens, no AWS keys; only paths, counts and sizes.
set -euo pipefail

SERVICE=""
MOUNT_PATH="/data"
TARGET=""
STAGING=""
METHOD="files"
DRY_RUN=0
DELETE=0
ENVIRONMENT=""
SSH_HOST="ssh.railway.com"
EXTRA_SYNC_ARGS=()

usage() {
  cat <<'EOF'
Usage: railway_volume_to_s3.sh --service <railway-service> [--mount-path /data] --target s3://<bucket>[/prefix]
                               [--staging migration/volume-staging/<service>] [--method files|scp]
                               [--environment production] [--delete] [--dry-run]
                               [-- <extra aws s3 sync args, e.g. --exclude 'tmp/*' --content-type image/jpeg>]

Options:
  --service NAME     Railway service the volume is attached to (as shown by `railway volume list`)
  --mount-path P     volume mount path inside the container (default /data; see `railway volume list --json` .mountPath)
  --target s3://...  destination bucket/prefix (the Terraform s3_media bucket, e.g. s3://acme-prod-media/uploads)
  --staging DIR      local directory for the copy (default migration/volume-staging/<service>); needs free disk >= volume size
  --method files     `railway volume files download <mount-path> <staging>` (default; newer CLI)
  --method scp       `scp -r <service>@ssh.railway.com:<mount-path>/. <staging>` (requires working `railway ssh`)
  --environment E    Railway environment for the CLI calls (default: the linked one)
  --delete           pass --delete to the S3 sync (mirror deletions; final run only)
  --dry-run          print the commands and the staging summary; no download, `aws s3 sync --dryrun`
  --                 everything after is appended to `aws s3 sync`

Requires: railway CLI (linked: `railway link`), aws CLI v2, and for --method scp an ssh/scp client whose key is
registered with Railway. Re-running only transfers changed files (both legs are incremental).

Outputs: <staging>/ (files), <staging>.manifest.tsv (relative path, bytes, sha256, content type), a count/size
summary on stdout. After the final sync: switch the app to S3 (SDK/presigned URLs via the task role), or mount
EFS instead if the code needs POSIX semantics (see scan_codebase.py "local filesystem writes" flag).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --service|-s) SERVICE="${2:-}"; shift 2 ;;
    --service=*) SERVICE="${1#*=}"; shift ;;
    --mount-path) MOUNT_PATH="${2:-}"; shift 2 ;;
    --mount-path=*) MOUNT_PATH="${1#*=}"; shift ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --target=*) TARGET="${1#*=}"; shift ;;
    --staging) STAGING="${2:-}"; shift 2 ;;
    --staging=*) STAGING="${1#*=}"; shift ;;
    --method) METHOD="${2:-}"; shift 2 ;;
    --method=*) METHOD="${1#*=}"; shift ;;
    --environment|-e) ENVIRONMENT="${2:-}"; shift 2 ;;
    --environment=*) ENVIRONMENT="${1#*=}"; shift ;;
    --delete) DELETE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; EXTRA_SYNC_ARGS=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$SERVICE" ] || { echo "error: --service is required" >&2; usage >&2; exit 2; }
[ -n "$TARGET" ] || { echo "error: --target s3://... is required" >&2; usage >&2; exit 2; }
case "$TARGET" in s3://*) ;; *) echo "error: --target must start with s3://" >&2; exit 2 ;; esac
case "$MOUNT_PATH" in /*) ;; *) echo "error: --mount-path must be absolute (e.g. /data)" >&2; exit 2 ;; esac
case "$METHOD" in files|scp) ;; *) echo "error: --method must be files or scp" >&2; exit 2 ;; esac
TARGET="${TARGET%/}"
[ -n "$STAGING" ] || STAGING="migration/volume-staging/${SERVICE}"

command -v aws >/dev/null 2>&1 || { echo "error: aws CLI not found" >&2; exit 1; }
if [ "$METHOD" = "files" ]; then
  command -v railway >/dev/null 2>&1 || { echo "error: railway CLI not found (npm i -g @railway/cli | brew install railway)" >&2; exit 1; }
else
  command -v scp >/dev/null 2>&1 || { echo "error: scp not found (install an OpenSSH client)" >&2; exit 1; }
  command -v railway >/dev/null 2>&1 || echo "warn: railway CLI not found; cannot verify the service, continuing with scp only"
fi

ENV_ARGS=()
[ -n "$ENVIRONMENT" ] && ENV_ARGS=(--environment "$ENVIRONMENT")

mkdir -p "$STAGING"
MANIFEST="${STAGING%/}.manifest.tsv"
SYNC_FLAGS=(--only-show-errors --no-progress)
[ "$DRY_RUN" -eq 1 ] && SYNC_FLAGS+=(--dryrun)
[ "$DELETE" -eq 1 ] && SYNC_FLAGS+=(--delete)

echo "== Railway volume: service '$SERVICE' mount '$MOUNT_PATH' -> $STAGING -> $TARGET  (method: $METHOD, dry-run: $DRY_RUN)"

# ---- sanity: does the service/volume exist? (names only; best effort, the CLI JSON shape varies)
if command -v railway >/dev/null 2>&1; then
  vols="$(railway volume list --json "${ENV_ARGS[@]}" 2>/dev/null || true)"
  if [ -n "$vols" ] && command -v jq >/dev/null 2>&1; then
    mounts="$(printf '%s' "$vols" | jq -r '.. | objects | select(has("mountPath")) | .mountPath' 2>/dev/null | sort -u | paste -sd, - || true)"
    [ -n "$mounts" ] && echo "   volumes in this environment (mount paths): $mounts"
    if [ -n "$mounts" ] && ! printf '%s' "$mounts" | tr ',' '\n' | grep -qx "$MOUNT_PATH"; then
      echo "warn: '$MOUNT_PATH' is not among the listed mount paths; check --mount-path (continuing)"
    fi
  fi
fi

# ---- step 1: volume -> staging
echo "-- step 1/2: download volume contents"
case "$METHOD" in
  files)
    cmd=(railway volume files download "$MOUNT_PATH" "$STAGING" --service "$SERVICE" "${ENV_ARGS[@]}")
    ;;
  scp)
    # trailing /. copies the directory CONTENTS into the staging dir (not a nested /data folder)
    cmd=(scp -r -p -o BatchMode=yes "${SERVICE}@${SSH_HOST}:${MOUNT_PATH}/." "$STAGING")
    echo "   (scp relies on the same SSH access as 'railway ssh --service $SERVICE'; test that first)"
    ;;
esac
printf '   $ %s\n' "${cmd[*]}"
if [ "$DRY_RUN" -eq 0 ]; then
  if ! "${cmd[@]}"; then
    echo "error: download failed." >&2
    if [ "$METHOD" = "files" ]; then
      echo "       If the CLI reports an unknown command, upgrade it (npm i -g @railway/cli) or use --method scp." >&2
    else
      echo "       Check: service running? 'railway ssh --service $SERVICE' works? SSH key linked in Railway account settings?" >&2
    fi
    exit 1
  fi
fi

# ---- manifest + summary of the staging tree
count=0; bytes=0
if [ "$DRY_RUN" -eq 0 ] || [ -n "$(find "$STAGING" -type f -print -quit 2>/dev/null)" ]; then
  {
    printf 'path\tbytes\tsha256\tcontent_type\n'
    while IFS= read -r -d '' f; do
      relp="${f#"$STAGING"/}"
      sz="$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")"
      sum="$( (sha256sum "$f" 2>/dev/null || shasum -a 256 "$f") | cut -d' ' -f1)"
      ctype="$(file --mime-type -b "$f" 2>/dev/null || echo application/octet-stream)"
      printf '%s\t%s\t%s\t%s\n' "$relp" "$sz" "$sum" "$ctype"
    done < <(find "$STAGING" -type f -print0 | sort -z)
  } >"$MANIFEST"
  count="$(($(wc -l <"$MANIFEST") - 1))"
  bytes="$(awk -F'\t' 'NR>1 {s+=$2} END {print s+0}' "$MANIFEST")"
fi
noext="$(awk -F'\t' 'NR>1 && $1 !~ /\.[A-Za-z0-9]+$/ {n++} END {print n+0}' "$MANIFEST" 2>/dev/null || echo 0)"
echo "   staged: $count files, $bytes bytes  (manifest: $MANIFEST)"
if [ "${noext:-0}" -gt 0 ]; then
  echo "   note: $noext file(s) have no extension -> S3 will store them as binary/octet-stream. Use '-- --content-type <type>'"
  echo "         for a uniform tree, or set types afterwards with 'aws s3 cp --recursive --metadata-directive REPLACE --content-type'."
  echo "         The manifest's content_type column (from 'file --mime-type') is the per-object source of truth."
fi

# ---- step 2: staging -> S3
echo "-- step 2/2: $STAGING -> $TARGET  (AWS account $(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '?'))"
printf '   $ aws s3 sync %s %s %s %s\n' "$STAGING" "$TARGET" "${SYNC_FLAGS[*]}" "${EXTRA_SYNC_ARGS[*]:-}"
aws s3 sync "$STAGING" "$TARGET" "${SYNC_FLAGS[@]}" "${EXTRA_SYNC_ARGS[@]}"

if [ "$DRY_RUN" -eq 0 ]; then
  remote="$(aws s3 ls "$TARGET/" --recursive --summarize 2>/dev/null | sed -nE 's/^ *Total (Objects|Size): ([0-9]+)/\1=\2/p' | paste -sd' ' - || echo '?')"
  echo "done: local files=$count bytes=$bytes; remote under $TARGET: ${remote:-?}"
  echo "Re-run before cutover to pick up new files (both legs are incremental; add --delete on the final run to mirror"
  echo "deletions). Then point the app at S3 (task role, no static keys) and rewrite stored paths using $MANIFEST."
else
  echo "dry-run complete (nothing downloaded or uploaded; staged files currently: $count)"
fi
