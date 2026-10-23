# shellcheck shell=bash
# Fingerprints of secret values, shared by breach_check.sh (writes and verifies them) and
# put_secrets.sh (refuses to upload a value whose fingerprint was recorded as exposed).
#
# Recipe: sha256 over the value's base64 as produced by jq's @base64. The value itself never reaches
# argv, stdout or an echoed variable; only the base64 form passes through a pipe into the hasher.
# Both sides must use this exact recipe, or nothing will ever match.
#
# Values shorter than FP_MIN_LENGTH are skipped: they are config ("info", "8000", "true"), and
# fingerprinting them would flag every app that sets the same port.

FP_MIN_LENGTH=8

fp_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# fp_entries <json-object-file>
# Prints "KEY<TAB>fingerprint" for every value of at least FP_MIN_LENGTH characters.
fp_entries() {
  local key b64
  jq -r --argjson min "$FP_MIN_LENGTH" '
    to_entries[]
    | select((.value | tostring | length) >= $min)
    | "\(.key)\t\(.value | tostring | @base64)"' "$1" |
    while IFS=$'\t' read -r key b64; do
      printf '%s\t%s\n' "$key" "$(printf '%s' "$b64" | fp_sha256)"
    done
}
