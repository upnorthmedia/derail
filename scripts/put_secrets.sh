#!/usr/bin/env bash
# put_secrets.sh - load a KEY=VALUE .env file into ONE AWS Secrets Manager secret as a JSON object.
# The Terraform secrets module creates that secret as "<project>-<env>/app" (for example
# "lumen-prod/app"; output app_secret_name) and the ECS task definition reads keys from it with
# valueFrom = "<arn>:<KEY>::". This script only writes the value; it never prompts: every key comes
# from the env file.
#
# Secret hygiene:
#   - values are parsed by jq straight from the file into a temp file created under umask 077
#     (never through argv, never echoed) and the temp file is deleted on exit
#   - stdout shows key NAMES, counts, classifications and the new VersionId only
#   - --diff compares key names (and whether values differ) against the live secret without
#     printing any value
#   - RAILWAY_* / VERCEL_* keys are refused: they are platform-injected and must not be copied
#   - when an exposed-value fingerprint file exists (breach_check.sh --fingerprint), any value whose
#     fingerprint is in it is refused: a value that leaked from Railway must be rotated, not moved
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fingerprint.sh
. "$SCRIPT_DIR/lib/fingerprint.sh"

SECRET_NAME=""
ENV_FILE=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
DRY_RUN=0
DIFF=0
CREATE=0
KMS_KEY_ID=""
ALLOW_PUBLIC=0
BURNED=""
BURNED_CHECK=1
CARRYOVER=()

usage() {
  cat <<'EOF'
Usage: put_secrets.sh --secret-name <project>-<env>/app --env-file migration/.secrets/aws.prod.env
                      [--region us-east-1] [--dry-run] [--diff] [--create [--kms-key-id <id>]]
                      [--allow-public-keys] [--burned-hashes FILE] [--allow-carryover KEY]...
                      [--no-burned-check]

  --secret-name  name created by the Terraform secrets module: "<project>-<env>/app", e.g. lumen-prod/app
                 (Terraform output app_secret_name). NOT "<project>/<env>/app".
  --env-file     KEY=VALUE file. Comments (#), blank lines, `export KEY=...`, single/double quotes and
                 JSON-style escapes in double quotes are handled. Values are never printed and never
                 prompted for: the file is the only input.
  --dry-run      parse + validate + print key names and the aws command; do not call AWS
  --diff         compare key names with the current secret value (and count values that differ);
                 does not write. Prints names only.
  --create       create the secret if it does not exist (otherwise Terraform should own it:
                 aws_secretsmanager_secret with the value written by this script, not by TF)
  --kms-key-id   CMK for --create (default: aws/secretsmanager)
  --allow-public-keys   allow NEXT_PUBLIC_* / VITE_* keys (normally build args, not runtime secrets)
  --burned-hashes FILE  exposed-value fingerprints written by `breach_check.sh --fingerprint`.
                 Default: railway.burned.sha256 next to the env file, if it exists. When present,
                 every value whose fingerprint is listed is refused (names are printed, values never).
                 No file means no check: an ordinary, non-breach migration is unaffected.
  --allow-carryover KEY  accept KEY even though its value matches an exposed fingerprint (repeatable).
                 For values that are not secrets but happened to be fingerprinted.
  --no-burned-check      skip the exposed-value check entirely

Refuses: RAILWAY_*, VERCEL_* keys, invalid identifiers, duplicate keys, empty file, and values
that match an exposed-value fingerprint (see --burned-hashes).
Requires: aws CLI v2 (credentials with secretsmanager:PutSecretValue [+ GetSecretValue for --diff]), jq.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --secret-name) SECRET_NAME="${2:-}"; shift 2 ;;
    --secret-name=*) SECRET_NAME="${1#*=}"; shift ;;
    --env-file) ENV_FILE="${2:-}"; shift 2 ;;
    --env-file=*) ENV_FILE="${1#*=}"; shift ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --region=*) REGION="${1#*=}"; shift ;;
    --kms-key-id) KMS_KEY_ID="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --diff) DIFF=1; shift ;;
    --create) CREATE=1; shift ;;
    --allow-public-keys) ALLOW_PUBLIC=1; shift ;;
    --burned-hashes) BURNED="${2:-}"; shift 2 ;;
    --burned-hashes=*) BURNED="${1#*=}"; shift ;;
    --allow-carryover) CARRYOVER+=("${2:-}"); shift 2 ;;
    --allow-carryover=*) CARRYOVER+=("${1#*=}"); shift ;;
    --no-burned-check) BURNED_CHECK=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$SECRET_NAME" ] || { echo "error: --secret-name is required" >&2; usage >&2; exit 2; }
[ -n "$ENV_FILE" ] || { echo "error: --env-file is required" >&2; usage >&2; exit 2; }
[ -f "$ENV_FILE" ] || { echo "error: $ENV_FILE not found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
if [ "$DRY_RUN" -eq 0 ]; then
  command -v aws >/dev/null 2>&1 || { echo "error: aws CLI not found" >&2; exit 1; }
fi
REGION_ARGS=()
[ -n "$REGION" ] && REGION_ARGS=(--region "$REGION")

umask 077
TMPDIR_SECURE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SECURE"' EXIT
LOCAL_JSON="$TMPDIR_SECURE/local.json"
REMOTE_JSON="$TMPDIR_SECURE/remote.json"

# ---- parse .env -> JSON object (inside jq; values never touch argv or stdout)
jq -Rn '
  def unq:
    if test("^\"") then
      (capture("^\"(?<s>(?:[^\"\\\\]|\\\\.)*)\"") | .s | ("\"" + . + "\"") | (fromjson? // .))
    elif test("^'"'"'") then
      (capture("^'"'"'(?<s>[^'"'"']*)'"'"'") | .s)
    else
      (sub("\\s+#.*$"; "") | sub("\\s+$"; ""))
    end;
  [ inputs
    | sub("\r$"; "")
    | select(test("^\\s*(#|$)") | not)
    | sub("^\\s*export\\s+"; "")
    | select(test("^[A-Za-z_][A-Za-z0-9_]*\\s*="))
    | capture("^(?<k>[A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*(?<v>.*)$")
    | {key: .k, value: (.v | unq)} ]
  | . as $entries
  | {
      object: ($entries | from_entries),
      keys: ($entries | map(.key)),
      duplicates: ($entries | map(.key) | group_by(.) | map(select(length > 1) | .[0])),
      malformed: 0
    }' "$ENV_FILE" >"$TMPDIR_SECURE/parsed.json"

# lines that look like assignments but failed the identifier test (names only)
malformed="$(grep -vE '^\s*(#|$)' "$ENV_FILE" | sed -E 's/^\s*export\s+//' | grep -vE '^[A-Za-z_][A-Za-z0-9_]*\s*=' | sed -E 's/=.*$/=.../' | head -n 5 || true)"

jq '.object' "$TMPDIR_SECURE/parsed.json" >"$LOCAL_JSON"
# while-read instead of mapfile: macOS ships bash 3.2
KEYS=(); DUPES=()
while IFS= read -r k; do KEYS+=("$k"); done < <(jq -r '.keys[]' "$TMPDIR_SECURE/parsed.json")
while IFS= read -r k; do DUPES+=("$k"); done < <(jq -r '.duplicates[]' "$TMPDIR_SECURE/parsed.json")

echo "== put_secrets: $SECRET_NAME  <-  $ENV_FILE  (${#KEYS[@]} keys)"
if [ -n "$malformed" ]; then
  echo "error: lines that are not valid KEY=VALUE assignments (values hidden):" >&2
  printf '  %s\n' "$malformed" >&2
  exit 2
fi
[ ${#KEYS[@]} -gt 0 ] || { echo "error: no KEY=VALUE entries found in $ENV_FILE" >&2; exit 2; }
if [ ${#DUPES[@]} -gt 0 ]; then
  echo "error: duplicate keys: ${DUPES[*]}" >&2; exit 2
fi

# ---- classify + refuse platform keys
refused=(); public=(); empty=()
for k in "${KEYS[@]}"; do
  case "$k" in
    RAILWAY_*|VERCEL_*|RAILPACK_*|NIXPACKS_*) refused+=("$k") ;;
    NEXT_PUBLIC_*|VITE_*|REACT_APP_*|NUXT_PUBLIC_*|EXPO_PUBLIC_*) public+=("$k") ;;
  esac
done
while IFS= read -r k; do empty+=("$k"); done < <(jq -r 'to_entries[] | select(.value == "") | .key' "$LOCAL_JSON")
if [ ${#refused[@]} -gt 0 ]; then
  echo "error: refusing platform-injected keys (remove them from the file): ${refused[*]}" >&2
  exit 2
fi
if [ ${#public[@]} -gt 0 ] && [ "$ALLOW_PUBLIC" -eq 0 ]; then
  echo "error: ${#public[@]} public build-time keys present (${public[*]}). They belong in Docker build args, not a runtime secret. Remove them or pass --allow-public-keys." >&2
  exit 2
fi
[ ${#empty[@]} -gt 0 ] && echo "warn: ${#empty[@]} keys have EMPTY values (placeholders from vercel env pull?): ${empty[*]}"

echo "keys:"
printf '  %s\n' "${KEYS[@]}"
secretish="$(printf '%s\n' "${KEYS[@]}" | grep -cE '(WEBHOOK_URL|HOOK_URL|_DSN$|_TOKEN|_KEY|_SECRET|PASSWORD|PASSWD|PRIVATE|CREDENTIAL|SIGNING|^(DATABASE|POSTGRES|REDIS|MONGO|MYSQL)[A-Z_]*(URL|URI)$)' || true)"
echo "classification: ${#KEYS[@]} total, $secretish secret-like, $((${#KEYS[@]} - secretish)) config-like, ${#empty[@]} empty"

# ---- exposed-value check (breach_check.sh --fingerprint). Skipped when no fingerprint file exists.
if [ "$BURNED_CHECK" -eq 1 ] && [ "$DIFF" -eq 0 ]; then
  if [ -z "$BURNED" ] && [ -f "$(dirname "$ENV_FILE")/railway.burned.sha256" ]; then
    BURNED="$(dirname "$ENV_FILE")/railway.burned.sha256"
  fi
  if [ -n "$BURNED" ]; then
    [ -s "$BURNED" ] || { echo "error: --burned-hashes file '$BURNED' is missing or empty" >&2; exit 2; }
    cut -f1 "$BURNED" | sort -u >"$TMPDIR_SECURE/burned.hashes"
    burned_hits=(); carried=()
    while IFS=$'\t' read -r k fp; do
      grep -qxF "$fp" "$TMPDIR_SECURE/burned.hashes" || continue
      allowed=0
      for c in ${CARRYOVER[@]+"${CARRYOVER[@]}"}; do [ "$c" = "$k" ] && allowed=1; done
      if [ "$allowed" -eq 1 ]; then carried+=("$k"); else burned_hits+=("$k"); fi
    done < <(fp_entries "$LOCAL_JSON")
    if [ ${#burned_hits[@]} -gt 0 ]; then
      echo "error: ${#burned_hits[@]} value(s) match fingerprints of exposed Railway values ($BURNED): ${burned_hits[*]}" >&2
      echo "       Rotate them at their provider and put the NEW value in $ENV_FILE." >&2
      echo "       If one is not a secret, pass --allow-carryover KEY for it." >&2
      exit 2
    fi
    echo "exposed-value check: passed against $BURNED${carried[0]+ (carried over on purpose: ${carried[*]})}"
  fi
fi

# ---- diff mode
if [ "$DIFF" -eq 1 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "(dry-run) would run: aws secretsmanager get-secret-value --secret-id $SECRET_NAME --query SecretString --output text ${REGION_ARGS[*]}"
    exit 0
  fi
  if ! aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} --query SecretString --output text >"$REMOTE_JSON" 2>"$TMPDIR_SECURE/err"; then
    if grep -q ResourceNotFoundException "$TMPDIR_SECURE/err"; then
      echo "remote: secret does not exist yet -> all ${#KEYS[@]} keys would be added"; exit 0
    fi
    echo "error: get-secret-value failed: $(sed -E 's/[A-Za-z0-9+/=]{40,}/<redacted>/g' "$TMPDIR_SECURE/err" | head -n 2)" >&2; exit 1
  fi
  if ! jq -e 'type == "object"' "$REMOTE_JSON" >/dev/null 2>&1; then
    echo "remote: current SecretString is not a JSON object (plain string secret?) -> would be replaced by a JSON object with ${#KEYS[@]} keys"
    exit 0
  fi
  jq -n --slurpfile a "$LOCAL_JSON" --slurpfile b "$REMOTE_JSON" '
    ($a[0]) as $l | ($b[0]) as $r
    | {
        only_local: ([$l | keys[]] - [$r | keys[]]),
        only_remote: ([$r | keys[]] - [$l | keys[]]),
        changed: ([$l | keys[]] | map(. as $k | select(($r | has($k)) and ($l[$k] != $r[$k])))),
        unchanged: ([$l | keys[]] | map(. as $k | select(($r | has($k)) and ($l[$k] == $r[$k]))) | length)
      }
    | "remote keys: \($r | keys | length)   local keys: \($l | keys | length)",
      "  added   (\(.only_local | length)): \(.only_local | join(", "))",
      "  removed (\(.only_remote | length)): \(.only_remote | join(", "))  <- put-secret-value REPLACES the whole JSON; these would disappear",
      "  changed (\(.changed | length)): \(.changed | join(", "))",
      "  unchanged: \(.unchanged)"' -r
  exit 0
fi

# ---- write
CMD=(aws secretsmanager put-secret-value --secret-id "$SECRET_NAME" --secret-string "file://$LOCAL_JSON" ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} --query VersionId --output text)
if [ "$DRY_RUN" -eq 1 ]; then
  echo "(dry-run) would run: ${CMD[*]}"
  [ "$CREATE" -eq 1 ] && echo "(dry-run) would first run: aws secretsmanager create-secret --name $SECRET_NAME ${KMS_KEY_ID:+--kms-key-id $KMS_KEY_ID} (if missing)"
  echo "(dry-run) JSON size: $(wc -c <"$LOCAL_JSON" | tr -d ' ') bytes (limit 65536)"
  exit 0
fi

size="$(wc -c <"$LOCAL_JSON" | tr -d ' ')"
[ "$size" -le 65536 ] || { echo "error: secret JSON is $size bytes (> 64 KiB Secrets Manager limit); split it" >&2; exit 1; }

if ! aws secretsmanager describe-secret --secret-id "$SECRET_NAME" ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} >/dev/null 2>"$TMPDIR_SECURE/err"; then
  if grep -q ResourceNotFoundException "$TMPDIR_SECURE/err"; then
    if [ "$CREATE" -eq 1 ]; then
      create_args=(--name "$SECRET_NAME" --description "App runtime secrets (managed by put_secrets.sh)" ${REGION_ARGS[@]+"${REGION_ARGS[@]}"})
      [ -n "$KMS_KEY_ID" ] && create_args+=(--kms-key-id "$KMS_KEY_ID")
      arn="$(aws secretsmanager create-secret "${create_args[@]}" --query ARN --output text)"
      echo "created secret: $arn"
    else
      echo "error: secret '$SECRET_NAME' does not exist. Create it with Terraform (aws_secretsmanager_secret, no value) or pass --create." >&2
      exit 1
    fi
  else
    echo "error: describe-secret failed: $(head -n 1 "$TMPDIR_SECURE/err")" >&2; exit 1
  fi
fi

version="$("${CMD[@]}")"
echo "ok: $SECRET_NAME updated, ${#KEYS[@]} keys, VersionId=$version"
echo "next: reference it from the ECS task definition as secrets[].valueFrom = <secret-arn>:<KEY>:: and force a new deployment."
