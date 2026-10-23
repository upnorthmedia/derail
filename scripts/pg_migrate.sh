#!/usr/bin/env bash
# pg_migrate.sh - Railway Postgres -> RDS/Aurora PostgreSQL via pg_dump/pg_restore, with
# verification (row counts + checksums + sequences).
#
# Connection URLs come ONLY from environment variables (never from arguments, so they do not
# land in shell history or `ps`):
#   SRC_URL  postgresql://postgres:...@localhost:<tunnel-port>/railway   (railway connect --tunnel-only)
#   TGT_URL  postgresql://postgres:...@<rds-endpoint>:5432/postgres?sslmode=verify-full&sslrootcert=global-bundle.pem
#            (admin connection; the application database is created/used by --target-db)
#
# Subcommands:
#   preflight  versions, size, extensions (and availability on target), tables without PK, roles
#   dump       pg_dump -Fd -jN --compress=zstd --no-owner --no-privileges ... + counts/checksums
#   restore    create DB + extensions, pg_restore -jN --no-owner --no-privileges --no-comments
#              [--role], ANALYZE, counts/checksums diff -> OK / MISMATCH
#   verify     re-run counts/checksums on both sides and diff
#   roles      render sql/app_roles.sql.tpl and apply (passwords via APP_RW_PASSWORD /
#              APP_MIGRATE_PASSWORD env, read inside psql with \getenv; never echoed)
#   audit      read-only security inventory of the source (SRC_URL only): roles, SECURITY DEFINER
#              functions, triggers, event triggers, rules, extensions, schemas, FDWs, publications,
#              live connections -> <out>/db-audit-<stamp>.md with a sign-off checklist (sql/audit.sql)
#
# Nothing secret is ever printed: URLs are masked in all output, including --dry-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="$SCRIPT_DIR/sql"

OUT="migration/db"
JOBS=4
DRY_RUN=0
TARGET_DB=""
ROLE=""
DUMP_DIR=""
APP_OWNER="app_owner"
APP_RW="app_rw"
APP_MIGRATE="app_migrate"
EXIT_ON_ERROR=1
CLEAN=0
PG_MAJOR_CHECK=0
EXCLUDE_TABLE_DATA=()

usage() {
  cat <<'EOF'
Usage: SRC_URL=... TGT_URL=... pg_migrate.sh <preflight|dump|restore|verify|roles> [options]
       SRC_URL=... pg_migrate.sh audit [--out DIR] [--dry-run]

Options:
  --out DIR          working directory for dumps/logs (default migration/db)
  --jobs N           parallel jobs for pg_dump/pg_restore (default 4)
  --target-db NAME   application database on the target (default: db name from SRC_URL, else "app")
  --role ROLE        pg_restore --role (objects owned by this role; e.g. app_owner). Requires
                     the role to exist and the master user to be a member (see `roles`).
  --dump-dir DIR     dump directory for restore/verify (default: <out>/LATEST pointer)
  --clean            restore with --clean --if-exists (re-runnable into a scratch DB)
  --no-exit-on-error restore without --exit-on-error (tolerate benign RDS errors)
  --exclude-table-data PATTERN   dump: pass through to pg_dump --exclude-table-data (schema kept, rows
                     skipped). Repeatable. Typical: --exclude-table-data='spatial_ref_sys' (PostGIS
                     populates it from the extension; restoring the rows conflicts), session/log/cache tables.
  --pg-major-check   fail early (exit 1) when `pg_dump --version` major < the source server major
                     (SHOW server_version_num on SRC_URL). Without it the mismatch is only a WARN in
                     preflight. A newer pg_dump can always dump an older server; the reverse is unsupported.
  --app-owner/--app-rw/--app-migrate NAME   role names for `roles` (defaults app_owner/app_rw/app_migrate)
  --dry-run          print the commands (URLs masked) without connecting
  -h, --help         this help

Environment:
  SRC_URL, TGT_URL   required (both), see header; `audit` needs SRC_URL only. PGSSLMODE defaults to "require"; PGTZ is forced to UTC.
  APP_RW_PASSWORD, APP_MIGRATE_PASSWORD   required by `roles` only.

Exit codes: 0 ok, 1 failure/mismatch, 2 usage error.
EOF
}

[ $# -ge 1 ] || { usage >&2; exit 2; }
CMD="$1"; shift
case "$CMD" in
  preflight|dump|restore|verify|roles|audit) ;;
  -h|--help) usage; exit 0 ;;
  *) echo "error: unknown subcommand '$CMD'" >&2; usage >&2; exit 2 ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    --jobs) JOBS="${2:-}"; shift 2 ;;
    --target-db) TARGET_DB="${2:-}"; shift 2 ;;
    --role) ROLE="${2:-}"; shift 2 ;;
    --dump-dir) DUMP_DIR="${2:-}"; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    --no-exit-on-error) EXIT_ON_ERROR=0; shift ;;
    --exclude-table-data) EXCLUDE_TABLE_DATA+=("${2:-}"); shift 2 ;;
    --exclude-table-data=*) EXCLUDE_TABLE_DATA+=("${1#*=}"); shift ;;
    --pg-major-check) PG_MAJOR_CHECK=1; shift ;;
    --app-owner) APP_OWNER="${2:-}"; shift 2 ;;
    --app-rw) APP_RW="${2:-}"; shift 2 ;;
    --app-migrate) APP_MIGRATE="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- guards
for tool in psql pg_dump pg_restore; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found (install PostgreSQL client tools >= source major)" >&2; exit 1; }
done
if [ "$CMD" = "audit" ]; then
  # audit reads the source only; TGT_URL is not needed (and not checked) here
  if [ -z "${SRC_URL:-}" ]; then
    echo "error: SRC_URL must be set in the environment (never pass it as an argument)." >&2
    echo "       e.g.  read -rs SRC_URL; export SRC_URL   (or source migration/.secrets/db.env)" >&2
    exit 2
  fi
  TGT_URL=""
elif [ -z "${SRC_URL:-}" ] || [ -z "${TGT_URL:-}" ]; then
  echo "error: SRC_URL and TGT_URL must both be set in the environment (never pass them as arguments)." >&2
  echo "       e.g.  read -rs SRC_URL; export SRC_URL   (or source migration/.secrets/db.env)" >&2
  exit 2
fi
case "$SRC_URL" in postgres://*|postgresql://*) ;; *) echo "error: SRC_URL must start with postgresql://" >&2; exit 2 ;; esac
if [ "$CMD" != "audit" ]; then
  case "$TGT_URL" in postgres://*|postgresql://*) ;; *) echo "error: TGT_URL must start with postgresql://" >&2; exit 2 ;; esac
fi

export PGTZ=UTC
export PGSSLMODE="${PGSSLMODE:-require}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}"
export PGOPTIONS="${PGOPTIONS:-} -c statement_timeout=0"

# mask secrets in connection strings: user:password@ in URLs; password= / sslpassword= as a URL query
# parameter (value ends at & or whitespace); and in key=value conninfo (value ends at whitespace, or is
# single-quoted with \' escapes; spaces around = allowed)
mask_stream() { sed -E -e 's#(://[^:/@]*):[^@]*@#\1:***@#g' -e 's#([?&])(ssl)?password=[^&[:space:]]*#\1\2password=***#g' -e 's#(^|[[:space:]])(ssl)?password[[:space:]]*=[[:space:]]*('"'"'([^'"'"'\\]|\\.)*'"'"'|[^[:space:]]*)#\1\2password=***#g'; }
mask() { printf '%s' "$1" | mask_stream; }
# db name from a URL path (postgresql://.../NAME?x=y)
url_db() { printf '%s' "$1" | sed -nE 's#^[a-z]+://[^/]*/([^?]*).*$#\1#p'; }
# replace the db name in a URL (keeps query string)
url_with_db() { printf '%s' "$1" | sed -E "s#^([a-z]+://[^/]*)/[^?]*#\1/$2#"; }

[ -n "$TARGET_DB" ] || TARGET_DB="$(url_db "$SRC_URL")"
[ -n "$TARGET_DB" ] || TARGET_DB="app"
APP_URL="$(url_with_db "$TGT_URL" "$TARGET_DB")"
MASTER_USER="$(printf '%s' "$TGT_URL" | sed -nE 's#^[a-z]+://([^:/@]+)(:[^@]*)?@.*#\1#p')"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "$OUT"
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# run_cmd <cmd...> : print masked (always) and execute (unless dry-run). URLs appear as args only
# for pg_dump/pg_restore/psql, and ps exposure is the same as any manual run of those tools.
run_cmd() {
  local shown=()
  for a in "$@"; do shown+=("$(mask "$a")"); done
  printf '  $ %s\n' "${shown[*]}"
  if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
  "$@"
}
# psql helpers (quiet, stop on error, no psqlrc)
pq() { local url="$1"; shift; run_cmd psql "$url" -X -q -v ON_ERROR_STOP=1 "$@"; }
# pq_at: tuples-only output to stdout (for capture); not printed via run_cmd to keep output clean
pq_at() { local url="$1"; shift; if [ "$DRY_RUN" -eq 1 ]; then echo "<dry-run>"; else psql "$url" -X -q -At -v ON_ERROR_STOP=1 "$@"; fi; }

echo "== pg_migrate $CMD"
echo "   source : $(mask "$SRC_URL")"
if [ "$CMD" = "audit" ]; then
  echo "   target : (not used by audit)"
else
  echo "   target : $(mask "$TGT_URL")  (app db: $TARGET_DB)"
fi
echo "   out    : $OUT   jobs: $JOBS   sslmode: $PGSSLMODE   dry-run: $DRY_RUN"

major_of() { printf '%s' "$1" | sed -nE 's/^[^0-9]*([0-9]+).*/\1/p'; }
pg_dump_major() { major_of "$(pg_dump --version | sed -nE 's/.* ([0-9]+)(\.[0-9]+)?.*/\1/p')"; }
# source server major from server_version_num (e.g. 180001 -> 18, 160015 -> 16)
src_server_major() {
  local num
  num="$(pq_at "$SRC_URL" -c 'SHOW server_version_num' 2>/dev/null || true)"
  case "$num" in ''|'<dry-run>') return 0 ;; esac
  printf '%s' "$(( num / 10000 ))"
}

# --pg-major-check: refuse to go on with a pg_dump older than the source server (applies to every
# subcommand; pg_dump/pg_restore/psql come from the same package so one check covers all three).
if [ "$PG_MAJOR_CHECK" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  _sm="$(src_server_major)"; _dm="$(pg_dump_major)"
  if [ -z "$_sm" ]; then
    echo "error: --pg-major-check: could not read server_version_num from SRC_URL (connection failed?)" >&2; exit 1
  fi
  if [ -n "$_dm" ] && [ "$_dm" -lt "$_sm" ]; then
    echo "error: pg_dump is major $_dm but the source server is PostgreSQL $_sm." >&2
    echo "       Install PostgreSQL client tools >= $_sm (Debian/Ubuntu: PGDG repo, apt install postgresql-client-$_sm;" >&2
    echo "       macOS: brew install postgresql@$_sm; or run the dump from a postgres:$_sm container) and re-run." >&2
    exit 1
  fi
  log "pg major check: pg_dump $_dm >= source $_sm (ok)"
fi

# ---------------------------------------------------------------- preflight
do_preflight() {
  local rep="$OUT/preflight-$STAMP.txt"
  {
    echo "# preflight $STAMP"
    echo "## client tools"
    pg_dump --version; pg_restore --version; psql --version
    echo "## source"
    src_ver="$(pq_at "$SRC_URL" -c 'SELECT version()')"; echo "$src_ver"
    echo "size: $(pq_at "$SRC_URL" -c 'SELECT pg_size_pretty(pg_database_size(current_database()))')"
    echo "tables: $(pq_at "$SRC_URL" -c "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema','pgbouncer')")"
    echo "large objects: $(pq_at "$SRC_URL" -c 'SELECT count(*) FROM pg_largeobject_metadata')"
    echo "schemas: $(pq_at "$SRC_URL" -c "SELECT string_agg(nspname, ', ') FROM pg_namespace WHERE nspname NOT IN ('pg_catalog','information_schema','pg_toast') AND nspname NOT LIKE 'pg_temp%'")"
    echo "## source extensions (extname|version|schema)"
    pq_at "$SRC_URL" -f "$SQL_DIR/extensions.sql" | tee "$OUT/extensions.src.txt"
    echo "## object owners on source (will be dropped by --no-owner)"
    pq_at "$SRC_URL" -c "SELECT DISTINCT pg_get_userbyid(relowner) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')"
    echo "## tables without primary key (checksums fall back to full-row ordering; logical replication would need REPLICA IDENTITY FULL)"
    pq_at "$SRC_URL" -c "SELECT n.nspname||'.'||c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind='r' AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast','pgbouncer') AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid=c.oid AND i.indisprimary) ORDER BY 1"
    echo "## publications / subscriptions (skipped by dump flags) / event triggers (carried by the dump) on source"
    pq_at "$SRC_URL" -c "SELECT 'publication: '||pubname FROM pg_publication UNION ALL SELECT 'subscription: '||subname FROM pg_subscription UNION ALL SELECT 'event trigger: '||evtname FROM pg_event_trigger"
    echo "## target"
    tgt_ver="$(pq_at "$TGT_URL" -c 'SELECT version()')"; echo "$tgt_ver"
    echo "target db '$TARGET_DB' exists: $(pq_at "$TGT_URL" -c "SELECT count(*) FROM pg_database WHERE datname='$TARGET_DB'")"
    echo "## extensions missing on target (name present on source but not in pg_available_extensions)"
    if [ "$DRY_RUN" -eq 0 ]; then
      avail="$(pq_at "$TGT_URL" -c 'SELECT name FROM pg_available_extensions')"
      missing=0
      while IFS='|' read -r ext ver schema; do
        [ -n "$ext" ] || continue
        if ! printf '%s\n' "$avail" | grep -qx "$ext"; then echo "MISSING: $ext ($ver, schema $schema)"; missing=1; fi
      done <"$OUT/extensions.src.txt"
      [ "$missing" -eq 0 ] && echo "none"
    fi
    echo "## version check"
    sm="$(src_server_major)"
    [ -n "$sm" ] || sm="$(major_of "$(printf '%s' "$src_ver" | sed -nE 's/^PostgreSQL ([0-9]+).*/\1/p')")"
    tm="$(major_of "$(printf '%s' "$tgt_ver" | sed -nE 's/^PostgreSQL ([0-9]+).*/\1/p')")"
    dm="$(pg_dump_major)"
    echo "source major=$sm (server_version_num) target major=$tm pg_dump major=$dm"
    if [ -n "$sm" ] && [ -n "$dm" ] && [ "$dm" -lt "$sm" ]; then
      echo "WARN: pg_dump ($dm) is older than the source server ($sm): install PostgreSQL client tools >= $sm (postgresql-client-$sm). Re-run with --pg-major-check to make this fatal."
    fi
    if [ -n "$sm" ] && [ -n "$tm" ] && [ "$tm" -lt "$sm" ]; then echo "WARN: target major ($tm) is older than source ($sm): downgrade restores are unsupported"; fi
  } | tee "$rep"
  log "preflight report: $rep"
}

# ---------------------------------------------------------------- dump
do_dump() {
  local dir="$OUT/dump-$STAMP"
  log "recording source counts/checksums"
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$dir"
    pq_at "$SRC_URL" -f "$SQL_DIR/rowcounts.sql" | sort >"$dir/counts.src.txt"
    pq_at "$SRC_URL" -f "$SQL_DIR/checksums.sql" | sort >"$dir/sums.src.txt"
    pq_at "$SRC_URL" -f "$SQL_DIR/extensions.sql" >"$dir/extensions.src.txt"
    pq_at "$SRC_URL" -c "SELECT n.nspname FROM pg_namespace n WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast','public','pgbouncer') AND n.nspname NOT LIKE 'pg_temp%' AND n.nspname NOT LIKE 'pg_toast%'" >"$dir/schemas.src.txt"
    log "tables: $(wc -l <"$dir/counts.src.txt" | tr -d ' ')  rows: $(awk -F'|' '{s+=$2} END{print s+0}' "$dir/counts.src.txt")"
    if grep -qi '^postgis|' "$dir/extensions.src.txt" && ! printf '%s\n' "${EXCLUDE_TABLE_DATA[@]:-}" | grep -q 'spatial_ref_sys'; then
      log "NOTE: PostGIS detected. spatial_ref_sys is populated by CREATE EXTENSION on the target; dumping its rows"
      log "      usually causes duplicate-key errors on restore. Consider: dump --exclude-table-data='spatial_ref_sys'"
    fi
  fi
  local excl=()
  for pat in "${EXCLUDE_TABLE_DATA[@]:-}"; do [ -n "$pat" ] && excl+=("--exclude-table-data=$pat"); done
  log "pg_dump (directory format, $JOBS jobs, zstd${excl[*]:+, ${#excl[@]} table-data exclusion(s)})"
  run_cmd pg_dump "$SRC_URL" \
    --format=directory --jobs="$JOBS" --compress=zstd \
    --no-owner --no-privileges \
    --no-subscriptions --no-publications \
    --quote-all-identifiers \
    --exclude-schema=pgbouncer \
    "${excl[@]}" \
    --file="$dir/data"
  if [ "$DRY_RUN" -eq 0 ]; then
    excl_json="$(printf '%s\n' "${EXCLUDE_TABLE_DATA[@]:-}" | grep -v '^$' | sed 's/"/\\"/g; s/^/"/; s/$/"/' | paste -sd, - || true)"
    printf '{"stamp":"%s","target_db":"%s","jobs":%s,"source_db":"%s","exclude_table_data":[%s]}\n' "$STAMP" "$TARGET_DB" "$JOBS" "$(url_db "$SRC_URL")" "${excl_json}" >"$dir/meta.json"
    printf '%s\n' "dump-$STAMP" >"$OUT/LATEST"
    log "dump complete: $dir  ($(du -sh "$dir/data" 2>/dev/null | cut -f1))"
    log "NOTE: anything committed on the source after the dump started is not included. Stop writes before the final dump."
  fi
}

resolve_dump_dir() {
  if [ -n "$DUMP_DIR" ]; then :; elif [ -f "$OUT/LATEST" ]; then DUMP_DIR="$OUT/$(cat "$OUT/LATEST")"; fi
  if [ -z "$DUMP_DIR" ]; then
    [ "$DRY_RUN" -eq 1 ] && { DUMP_DIR="$OUT/dump-<stamp>"; return 0; }
    echo "error: no dump found; pass --dump-dir or run 'dump' first" >&2; exit 1
  fi
  if [ "$DRY_RUN" -eq 0 ] && [ ! -d "$DUMP_DIR/data" ]; then
    echo "error: $DUMP_DIR/data is not a pg_dump directory" >&2; exit 1
  fi
}

# ---------------------------------------------------------------- restore
do_restore() {
  resolve_dump_dir
  local logf="$OUT/restore-$STAMP.log"
  log "restoring $DUMP_DIR -> db '$TARGET_DB'"

  # 1. database
  local exists="0"
  [ "$DRY_RUN" -eq 0 ] && exists="$(pq_at "$TGT_URL" -c "SELECT count(*) FROM pg_database WHERE datname='$TARGET_DB'")"
  if [ "$exists" = "0" ]; then
    if [ -n "$ROLE" ]; then
      pq "$TGT_URL" -c "CREATE DATABASE \"$TARGET_DB\" OWNER \"$ROLE\""
    else
      pq "$TGT_URL" -c "CREATE DATABASE \"$TARGET_DB\""
    fi
  else
    log "database '$TARGET_DB' already exists (idempotent: continuing)"
  fi

  # 2. schemas + extensions (from the source list captured at dump time)
  if [ "$DRY_RUN" -eq 0 ]; then
    if [ -n "$ROLE" ]; then
      # objects are created via SET ROLE $ROLE, so every schema must be owned by it
      pq "$APP_URL" -c "ALTER SCHEMA public OWNER TO \"$ROLE\""
    fi
    if [ -s "$DUMP_DIR/schemas.src.txt" ]; then
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        pq "$APP_URL" -c "CREATE SCHEMA IF NOT EXISTS \"$s\""
        [ -n "$ROLE" ] && pq "$APP_URL" -c "ALTER SCHEMA \"$s\" OWNER TO \"$ROLE\""
      done <"$DUMP_DIR/schemas.src.txt"
    fi
    if [ -s "$DUMP_DIR/extensions.src.txt" ]; then
      if grep -qi '^postgis|' "$DUMP_DIR/extensions.src.txt"; then
        log "NOTE: source has PostGIS. CREATE EXTENSION postgis fills spatial_ref_sys on the target; if the dump"
        log "      contains spatial_ref_sys rows they may conflict (duplicate key) and stop a --exit-on-error restore."
        log "      If that happens: re-dump with --exclude-table-data='spatial_ref_sys' (extension-owned tables are"
        log "      already excluded from counts/checksums, so verification is unaffected)."
      fi
      while IFS='|' read -r ext ver schema; do
        [ -n "$ext" ] || continue
        pq "$APP_URL" -c "CREATE EXTENSION IF NOT EXISTS \"$ext\" SCHEMA \"$schema\"" \
          || log "WARN: could not create extension $ext (not in rds.extensions? see preflight)"
      done <"$DUMP_DIR/extensions.src.txt"
    fi
  else
    echo "  (would CREATE SCHEMA / CREATE EXTENSION IF NOT EXISTS for each entry in $DUMP_DIR/extensions.src.txt)"
  fi

  # 3. TOC filter: skip SCHEMA/EXTENSION entries we pre-created above (otherwise pg_restore fails
  #    with "already exists" under --exit-on-error). Everything else is restored.
  local args=(--dbname="$APP_URL" --jobs="$JOBS" --no-owner --no-privileges --no-comments --verbose)
  [ -n "$ROLE" ] && args+=(--role="$ROLE")
  [ "$CLEAN" -eq 1 ] && args+=(--clean --if-exists)
  [ "$EXIT_ON_ERROR" -eq 1 ] && args+=(--exit-on-error)
  if [ "$DRY_RUN" -eq 0 ]; then
    local toc="$OUT/toc-$STAMP.list"
    pg_restore -l "$DUMP_DIR/data" >"$toc"
    local skip_re='^$'
    if [ -s "$DUMP_DIR/schemas.src.txt" ]; then
      while IFS= read -r s; do [ -n "$s" ] && skip_re="$skip_re|^[0-9]+; [0-9]+ [0-9]+ SCHEMA - $s "; done <"$DUMP_DIR/schemas.src.txt"
    fi
    if [ -s "$DUMP_DIR/extensions.src.txt" ]; then
      while IFS='|' read -r ext ver schema; do [ -n "$ext" ] && skip_re="$skip_re|^[0-9]+; [0-9]+ [0-9]+ EXTENSION - \"?$ext\"? "; done <"$DUMP_DIR/extensions.src.txt"
    fi
    grep -Ev "$skip_re" "$toc" >"$toc.filtered" || true
    log "TOC: $(grep -c '^[0-9]' "$toc") entries, $(( $(grep -c '^[0-9]' "$toc") - $(grep -c '^[0-9]' "$toc.filtered") )) pre-created entries skipped"
    args+=(--use-list="$toc.filtered")
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    run_cmd pg_restore "${args[@]}" --use-list="$OUT/toc-<stamp>.list.filtered" "$DUMP_DIR/data"
  else
    local shown=(); for a in pg_restore "${args[@]}" "$DUMP_DIR/data"; do shown+=("$(mask "$a")"); done
    printf '  $ %s\n' "${shown[*]}"
    if ! pg_restore "${args[@]}" "$DUMP_DIR/data" >"$logf" 2>&1; then
      log "pg_restore FAILED; error lines from $logf (first 10):"
      grep -nE 'pg_restore: (error|warning)|^ERROR:|^DETAIL:' "$logf" | head -n 10 | mask_stream
      log "last lines:"
      tail -n 5 "$logf" | mask_stream
      if grep -q 'duplicate key value violates unique constraint "spatial_ref_sys_pkey"' "$logf"; then
        log "HINT: PostGIS spatial_ref_sys rows conflict with the ones CREATE EXTENSION inserted: re-run dump with --exclude-table-data='spatial_ref_sys'"
      fi
      exit 1
    fi
    log "pg_restore ok (log: $logf, $(grep -c 'pg_restore:' "$logf" || true) lines)"
  fi

  # 4. post: ANALYZE, verify
  pq "$APP_URL" -c "ANALYZE"
  do_verify "$DUMP_DIR"
}

# ---------------------------------------------------------------- verify
do_verify() {
  local dir="${1:-}"
  if [ -z "$dir" ]; then resolve_dump_dir; dir="$DUMP_DIR"; fi
  [ "$DRY_RUN" -eq 1 ] && { echo "  (would run rowcounts.sql / checksums.sql on both sides and diff; then sequences_check.sql on target)"; return 0; }
  mkdir -p "$dir"
  # tables whose DATA was excluded at dump time (meta.json) are not compared; pg_dump patterns
  # (schema.table, table, wildcards * ?) are turned into a regex on "schema.table|".
  local excl_re='^$'
  if [ -f "$dir/meta.json" ] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      pat="$(printf '%s' "$pat" | sed -e 's/"//g' -e 's/[.]/\\./g' -e 's/\*/[^|]*/g' -e 's/?/[^|]/g')"
      case "$pat" in *'\.'*) excl_re="$excl_re|^${pat}\|" ;; *) excl_re="$excl_re|^[^.|]*\.${pat}\|" ;; esac
    done < <(jq -r '.exclude_table_data[]? // empty' "$dir/meta.json" 2>/dev/null)
  fi
  # grep exits 1 when every line is filtered out; that is not an error here
  filt() { grep -Ev "$excl_re" || [ $? -eq 1 ]; }
  log "counts/checksums: source"
  pq_at "$SRC_URL" -f "$SQL_DIR/rowcounts.sql" | sort | filt >"$dir/counts.src.$STAMP.txt"
  pq_at "$SRC_URL" -f "$SQL_DIR/checksums.sql" | sort | filt >"$dir/sums.src.$STAMP.txt"
  log "counts/checksums: target"
  pq_at "$APP_URL" -f "$SQL_DIR/rowcounts.sql" | sort | filt >"$dir/counts.dst.$STAMP.txt"
  pq_at "$APP_URL" -f "$SQL_DIR/checksums.sql" | sort | filt >"$dir/sums.dst.$STAMP.txt"
  if [ "$excl_re" != '^$' ]; then
    log "note: tables matching --exclude-table-data patterns from the dump are skipped in the comparison ($(jq -r '.exclude_table_data | join(", ")' "$dir/meta.json" 2>/dev/null))"
  fi
  local status=0
  if diff -u "$dir/counts.src.$STAMP.txt" "$dir/counts.dst.$STAMP.txt" >"$dir/counts.diff.$STAMP.txt"; then
    log "ROW COUNTS: OK ($(wc -l <"$dir/counts.src.$STAMP.txt" | tr -d ' ') tables)"
  else
    log "ROW COUNTS: MISMATCH (see $dir/counts.diff.$STAMP.txt)"; grep -E '^[-+][^-+]' "$dir/counts.diff.$STAMP.txt" | head -n 20; status=1
  fi
  if diff -u "$dir/sums.src.$STAMP.txt" "$dir/sums.dst.$STAMP.txt" >"$dir/sums.diff.$STAMP.txt"; then
    log "CHECKSUMS: OK"
  else
    log "CHECKSUMS: MISMATCH (see $dir/sums.diff.$STAMP.txt; volatile columns or TimeZone differences can cause this)"; grep -E '^[-+][^-+]' "$dir/sums.diff.$STAMP.txt" | head -n 20; status=1
  fi
  local seqs
  seqs="$(pq_at "$APP_URL" -f "$SQL_DIR/sequences_check.sql" || true)"
  if [ -n "$seqs" ]; then
    log "SEQUENCES: $(printf '%s\n' "$seqs" | wc -l | tr -d ' ') behind max(column) -> run: psql \"\$APP_URL\" -f $SQL_DIR/sequences_fix.sql"
    printf '%s\n' "$seqs" | head -n 10
    status=1
  else
    log "SEQUENCES: OK"
  fi
  local ext_src ext_dst
  ext_src="$(pq_at "$SRC_URL" -f "$SQL_DIR/extensions.sql" | cut -d'|' -f1 | sort)"
  ext_dst="$(pq_at "$APP_URL" -f "$SQL_DIR/extensions.sql" | cut -d'|' -f1 | sort)"
  if [ "$ext_src" = "$ext_dst" ]; then log "EXTENSIONS: OK"; else log "EXTENSIONS: differ"; diff <(printf '%s\n' "$ext_src") <(printf '%s\n' "$ext_dst") || true; status=1; fi
  if [ "$status" -eq 0 ]; then log "VERIFY: OK"; else log "VERIFY: MISMATCH"; fi
  return "$status"
}

# ---------------------------------------------------------------- roles
do_roles() {
  if [ "$DRY_RUN" -eq 0 ]; then
    [ -n "${APP_RW_PASSWORD:-}" ] || { echo "error: APP_RW_PASSWORD is not set (export it; it is read by psql via \\getenv, never printed)" >&2; exit 2; }
    [ -n "${APP_MIGRATE_PASSWORD:-}" ] || { echo "error: APP_MIGRATE_PASSWORD is not set" >&2; exit 2; }
  fi
  [ -n "$MASTER_USER" ] || { echo "error: could not parse the master user from TGT_URL" >&2; exit 2; }
  local rendered
  rendered="$(mktemp)"
  trap 'rm -f "$rendered"' RETURN
  sed -e "s/{{DB_NAME}}/$TARGET_DB/g" -e "s/{{APP_OWNER}}/$APP_OWNER/g" -e "s/{{APP_RW}}/$APP_RW/g" \
      -e "s/{{APP_MIGRATE}}/$APP_MIGRATE/g" -e "s/{{MASTER_USER}}/$MASTER_USER/g" "$SQL_DIR/app_roles.sql.tpl" >"$rendered"
  log "roles: owner=$APP_OWNER rw=$APP_RW migrate=$APP_MIGRATE db=$TARGET_DB master=$MASTER_USER"
  # the app DB must exist (roles are cluster-wide, grants are per-db)
  local exists="1"
  [ "$DRY_RUN" -eq 0 ] && exists="$(pq_at "$TGT_URL" -c "SELECT count(*) FROM pg_database WHERE datname='$TARGET_DB'")"
  if [ "$exists" = "0" ]; then pq "$TGT_URL" -c "CREATE DATABASE \"$TARGET_DB\""; fi
  pq "$APP_URL" -f "$rendered"
  log "roles applied. Store the two passwords in Secrets Manager (put_secrets.sh); never in Terraform state."
}

# ---------------------------------------------------------------- audit
# Read-only inventory of what pg_dump would carry over (and who can log in), for a person to sign off
# before the final dump. After a credential leak the source may hold objects an intruder added.
do_audit() {
  local rep="$OUT/db-audit-$STAMP.md"
  if [ "$DRY_RUN" -eq 1 ]; then
    run_cmd psql "$SRC_URL" -X -q -v ON_ERROR_STOP=1 -f "$SQL_DIR/audit.sql"
    echo "  (would write $rep)"
    return 0
  fi
  local tmp="$rep.partial"
  {
    echo "# Database audit $STAMP"
    echo
    echo "Source: \`$(mask "$SRC_URL")\` (read-only session). Generated by \`pg_migrate.sh audit\` from \`sql/audit.sql\`."
    echo "No row data, passwords, function bodies or query text are included: functions are identified by"
    echo "length and a SHA-256 prefix of their definition, so re-run after cleanup and diff two reports."
    echo
  } >"$tmp"
  if ! psql "$SRC_URL" -X -q -v ON_ERROR_STOP=1 -f "$SQL_DIR/audit.sql" >>"$tmp"; then
    rm -f "$tmp"
    log "audit FAILED (psql error above); no report written"
    exit 1
  fi
  cat >>"$tmp" <<'EOF'

## Sign-off

`dump` passes `--no-owner --no-privileges --no-publications --no-subscriptions`, so roles, grants,
publications and subscriptions are not copied. Everything else listed above that lives in this
database is: functions, triggers, event triggers, rules, schemas, extensions, foreign servers and
user mappings (a user mapping's options, including any password, are written to the dump in plain text).

- [ ] 1-2. Every role is known and has a purpose; no unexpected login, superuser, createrole,
      bypassrls or replication attribute, valid_until or membership (e.g. pg_read_server_files,
      pg_execute_server_program). Unknown roles are not recreated on the target.
- [ ] 3. Every per-role / per-database setting name is expected.
- [ ] 4. Every SECURITY DEFINER function is the app's own (owner, language, set_options includes
      search_path); extension-owned ones match the extension list.
- [ ] 5. Every trigger and the function it calls comes from the app's migrations.
- [ ] 6. Event triggers: none, or each is explained.
- [ ] 7. Every rule is explained.
- [ ] 8. Every extension is one the app uses (untrusted languages, dblink and *_fdw need a reason).
- [ ] 9-10. Every schema and object owner is expected.
- [ ] 11. Foreign servers / user mappings: none, or each is explained (a mapping stores credentials
      for another server: treat those as exposed too, and drop unexplained ones before dumping).
- [ ] 12. Publications / subscriptions: none, or each is explained (one you did not create may mean
      data was replicated out).
- [ ] 13. Every connected user, application_name and client_addr is yours.
- [ ] Anything unexplained is recorded in BREACH.md, removed on the source (or excluded from the
      dump), and this audit is re-run and diffed before the final dump.

Signed off by: ____________________  Date (UTC): ____________
EOF
  mv "$tmp" "$rep"
  # stdout summary: row count per section (psql table footers), nothing else from the report
  awk '/^## [0-9]/ { h = $0; sub(/^## /, "", h); sub(/ \(.*$/, "", h) } /^\([0-9]+ rows?\)$/ { gsub(/[()]/, ""); printf "   %-60s %s\n", h, $0 }' "$rep"
  log "audit report: $rep  (review every section and complete the sign-off checklist)"
}

case "$CMD" in
  preflight) do_preflight ;;
  dump) do_dump ;;
  restore) do_restore ;;
  verify) do_verify ;;
  roles) do_roles ;;
  audit) do_audit ;;
esac
