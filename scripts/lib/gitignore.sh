# shellcheck shell=bash
# gitignore_add_dir <dir>
# Appends "<dir>/" (relative to the repository root) to that repository's .gitignore, once. Outside a
# git repository the current directory stands in for the root, as the inventory scripts always did.
# Paths are compared physically (pwd -P) because git reports the resolved root (/private/var on macOS).
# The root itself is never added: there is no relative entry for it.
gitignore_add_dir() {
  local dir root entry
  dir="$(cd "$1" && pwd -P)"
  root="$(cd "$1" && git rev-parse --show-toplevel 2>/dev/null)" || root="$(pwd -P)"
  case "$dir/" in
    "$root"/) echo "gitignore: $dir is the repository root itself; not adding it (use a subdirectory)"; return 0 ;;
    "$root"/*) entry="${dir#"$root"/}/" ;;
    *) echo "gitignore: $dir is outside $root; add it to your ignore rules yourself"; return 0 ;;
  esac
  if ! grep -qxF -- "$entry" "$root/.gitignore" 2>/dev/null; then
    printf '%s\n' "$entry" >>"$root/.gitignore"
    echo "gitignore: added '$entry' to $root/.gitignore"
  fi
}
