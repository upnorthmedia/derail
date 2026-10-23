#!/usr/bin/env bash
# shellcheck disable=SC2034  # rc and SECRETS are read by check() through eval
# Tests for `pg_migrate.sh audit` (and restore's EVENT TRIGGER / USER MAPPING handling) against a real
# throwaway PostgreSQL (no mocks).
#
# Starts postgres:17 in Docker on a random localhost port, builds a small app schema, plants what an
# intruder holding a leaked DATABASE_URL could leave behind (extra login role, SECURITY DEFINER
# function, trigger, event trigger, schema, rule, foreign server + user mapping), runs the audit and
# asserts every planted object is listed and no planted password or function body is written.
#
#   bash scripts/tests/test_pg_audit.sh                 # needs docker + psql/pg_dump/pg_restore on PATH
#   BASH_UNDER_TEST=/bin/bash bash scripts/tests/...    # e.g. macOS bash 3.2
#   PG_AUDIT_ADMIN_URL=postgresql://postgres:pw@host:5432/postgres bash scripts/tests/...
#       use an existing THROWAWAY superuser connection instead of starting a container
#       (objects are created in a fresh database named pg_audit_test, dropped at the end)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
SH="${BASH_UNDER_TEST:-bash}"

T="$(mktemp -d)"
CID=""
ADMIN_URL="${PG_AUDIT_ADMIN_URL:-}"
cleanup() {
  if [ -n "$CID" ]; then docker rm -f "$CID" >/dev/null 2>&1 || true; fi
  if [ -n "${PG_AUDIT_ADMIN_URL:-}" ]; then
    for db in pg_audit_test rs_evt rs_um r_evt_role r_evt_keep r_evt_keep_role r_um r_um_keep r_um_fail; do
      psql "$ADMIN_URL" -X -q -c "DROP DATABASE IF EXISTS $db WITH (FORCE)" >/dev/null 2>&1 || true
    done
    for role in intruder ghost app_owner; do
      psql "$ADMIN_URL" -X -q -c "DROP ROLE IF EXISTS $role" >/dev/null 2>&1 || true
    done
  fi
  if [ -n "${KEEP:-}" ]; then echo "kept $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT
PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
# Inside checks, pipe into `grep >/dev/null`, not `grep -q`: -q exits early and, with pipefail,
# the writer's SIGPIPE turns a match into a random failure.
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

for tool in psql pg_dump pg_restore; do
  command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not on PATH"; exit 0; }
done

SUPER_PW="FIXTUREsuperpass0001"
export PGSSLMODE=disable PGCONNECT_TIMEOUT=5
if [ -z "$ADMIN_URL" ]; then
  command -v docker >/dev/null 2>&1 || { echo "SKIP: docker not available and PG_AUDIT_ADMIN_URL not set"; exit 0; }
  CID="$(docker run -d --rm -e POSTGRES_PASSWORD="$SUPER_PW" -p 127.0.0.1::5432 postgres:17)"
  PORT="$(docker port "$CID" 5432/tcp | head -n 1 | sed -E 's/.*:([0-9]+)$/\1/')"
  ADMIN_URL="postgresql://postgres:$SUPER_PW@127.0.0.1:$PORT/postgres"
fi
# the official image restarts once after initdb, so wait for a few consecutive successes
ready=0
for _ in $(seq 1 60); do
  if psql "$ADMIN_URL" -X -q -At -c 'SELECT 1' >/dev/null 2>&1; then
    ready=$((ready + 1)); [ "$ready" -ge 3 ] && break
  else
    ready=0
  fi
  sleep 1
done
[ "$ready" -ge 3 ] || { echo "error: postgres did not become ready"; exit 1; }

psql "$ADMIN_URL" -X -q -v ON_ERROR_STOP=1 -c 'CREATE DATABASE pg_audit_test' >/dev/null
DB_URL="$(printf '%s' "$ADMIN_URL" | sed -E 's#^([a-z]+://[^/]*)/[^?]*#\1/pg_audit_test#')"

# ---------------------------------------------------------------- app schema + planted objects
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
SET client_min_messages TO error;  -- quiet the wal_level warning from CREATE PUBLICATION
CREATE TABLE public.users (id bigserial PRIMARY KEY, email text NOT NULL);
CREATE TABLE public.orders (id bigserial PRIMARY KEY, user_id bigint REFERENCES public.users(id), total numeric);
INSERT INTO public.users (email) VALUES ('rowdata-FIXTURE@example.test');
CREATE FUNCTION public.order_total(bigint) RETURNS numeric LANGUAGE sql AS 'SELECT sum(total) FROM public.orders WHERE user_id = $1';

-- planted
CREATE ROLE intruder LOGIN CREATEROLE BYPASSRLS PASSWORD 'FIXTUREintruderpass0001' VALID UNTIL '2099-01-01';
GRANT pg_read_server_files TO intruder;
CREATE SCHEMA shadow AUTHORIZATION intruder;
CREATE TABLE shadow.copied (email text);
CREATE FUNCTION public.backdoor_login(text) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  -- FIXTUREbodymarker0001
  RETURN $1 = 'FIXTUREbodymarker0001';
END $$;
ALTER FUNCTION public.backdoor_login(text) OWNER TO intruder;
CREATE FUNCTION shadow.copy_email() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN INSERT INTO shadow.copied VALUES (NEW.email); RETURN NEW; END $$;
CREATE TRIGGER exfil_users AFTER INSERT ON public.users FOR EACH ROW EXECUTE FUNCTION shadow.copy_email();
CREATE FUNCTION public.on_ddl() RETURNS event_trigger LANGUAGE plpgsql AS $$ BEGIN END $$;
CREATE EVENT TRIGGER watch_ddl ON ddl_command_start EXECUTE FUNCTION public.on_ddl();
CREATE RULE mirror_orders AS ON INSERT TO public.orders DO ALSO INSERT INTO shadow.copied VALUES ('x');
CREATE EXTENSION postgres_fdw;
CREATE SERVER exfil_srv FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host 'exfil.invalid', dbname 'x');
CREATE USER MAPPING FOR intruder SERVER exfil_srv OPTIONS (user 'x', password 'FIXTUREmappingpass0001');
CREATE PUBLICATION leak_pub FOR TABLE public.users;
SQL

# an open, non-idle session from the intruder role (held for the duration of the audit)
INTRUDER_URL="$(printf '%s' "$DB_URL" | sed -E 's#://[^@]*@#://intruder:FIXTUREintruderpass0001@#')"
PGAPPNAME=planted-session psql "$INTRUDER_URL" -X -q -c 'SELECT pg_sleep(60)' >/dev/null 2>&1 &
SLEEPER=$!
for _ in $(seq 1 20); do
  n="$(psql "$DB_URL" -X -q -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name='planted-session' AND state='active'")"
  [ "$n" -ge 1 ] && break
  sleep 0.5
done

SECRETS="FIXTUREsuperpass0001|FIXTUREintruderpass0001|FIXTUREmappingpass0001|FIXTUREbodymarker0001|rowdata-FIXTURE"
cd "$T"

echo "== pg_migrate.sh audit"
rc=0; SRC_URL="$DB_URL" env -u TGT_URL "$SH" "$SCRIPTS/pg_migrate.sh" audit --out out >stdout.txt 2>stderr.txt || rc=$?
kill "$SLEEPER" >/dev/null 2>&1 || true
wait "$SLEEPER" 2>/dev/null || true
REP="$(ls out/db-audit-*.md 2>/dev/null | head -n 1 || true)"
check "exits 0 with only SRC_URL set" '[ "$rc" -eq 0 ]'
check "writes out/db-audit-<stamp>.md" '[ -n "$REP" ] && [ -s "$REP" ]'
[ -n "$REP" ] || REP=out/missing.md
check "lists the planted login role" 'grep >/dev/null "intruder" "$REP"'
check "shows role attributes (createrole/bypassrls/valid until)" 'grep -i "intruder" "$REP" | grep >/dev/null "2099"'
check "lists the role membership" 'grep "pg_read_server_files" "$REP" | grep >/dev/null "intruder"'
check "lists the SECURITY DEFINER function with its owner" 'grep "backdoor_login" "$REP" | grep >/dev/null "intruder"'
check "lists the trigger and the function it calls" 'grep "exfil_users" "$REP" | grep >/dev/null "copy_email"'
check "lists the event trigger" 'grep >/dev/null "watch_ddl" "$REP"'
check "lists the rule" 'grep >/dev/null "mirror_orders" "$REP"'
check "lists extensions with versions" 'grep "postgres_fdw" "$REP" | grep >/dev/null "[0-9][.][0-9]"'
check "lists the non-default schema and its owner" 'grep "shadow" "$REP" | grep >/dev/null "intruder"'
check "lists the foreign server" 'grep >/dev/null "exfil_srv" "$REP"'
check "lists the publication" 'grep >/dev/null "leak_pub" "$REP"'
check "lists the planted live session" 'grep "planted-session" "$REP" | grep >/dev/null "intruder"'
check "ends with a sign-off checklist" 'tail -n 20 "$REP" | grep >/dev/null "\- \[ \]"'
check "no planted password, function body or row data in the report" '! grep -E "$SECRETS" "$REP" >/dev/null'
check "no planted password or body on stdout/stderr" '! cat stdout.txt stderr.txt | grep -E "$SECRETS" >/dev/null'
check "connection URL is masked on stdout" 'grep >/dev/null "postgres:\*\*\*@" stdout.txt'
check "did not change the source (event trigger still enabled, no new objects)" \
  '[ "$(psql "$DB_URL" -X -q -At -c "SELECT evtenabled FROM pg_event_trigger WHERE evtname='"'"'watch_ddl'"'"'")" = "O" ]'

echo "== guards"
rc=0; env -u SRC_URL -u TGT_URL "$SH" "$SCRIPTS/pg_migrate.sh" audit --out out2 >g1.txt 2>&1 || rc=$?
check "audit without SRC_URL exits 2" '[ "$rc" -eq 2 ]'
rc=0; SRC_URL="$DB_URL" env -u TGT_URL "$SH" "$SCRIPTS/pg_migrate.sh" preflight --out out3 >g2.txt 2>&1 || rc=$?
check "preflight still requires TGT_URL (exit 2)" '[ "$rc" -eq 2 ]'
rc=0; SRC_URL="$DB_URL" env -u TGT_URL "$SH" "$SCRIPTS/pg_migrate.sh" audit --dry-run --out out4 >g3.txt 2>&1 || rc=$?
check "audit --dry-run exits 0" '[ "$rc" -eq 0 ]'
check "audit --dry-run writes no report" '! ls out4/db-audit-*.md >/dev/null 2>&1'
check "audit --dry-run masks the URL" '! grep -E "$SECRETS" g3.txt >/dev/null && grep >/dev/null "postgres:\*\*\*@" g3.txt'

echo "== password in the URL query string"
case "$DB_URL" in *\?*) qsep='&' ;; *) qsep='?' ;; esac
QS_URL="$(printf '%s' "$DB_URL" | sed -E 's#://([^:/@]*):[^@]*@#://\1@#')${qsep}application_name=pg-audit-qs&password=$SUPER_PW"
rc=0; SRC_URL="$QS_URL" env -u TGT_URL "$SH" "$SCRIPTS/pg_migrate.sh" audit --out out5 >q1.txt 2>&1 || rc=$?
check "audit with ?password= exits 0" '[ "$rc" -eq 0 ]'
check "query-string password is masked on stdout" '! grep "$SUPER_PW" q1.txt >/dev/null && grep >/dev/null "password=\*\*\*" q1.txt'
check "query-string password is not in the report" '! cat out5/db-audit-*.md 2>/dev/null | grep "$SUPER_PW" >/dev/null'
rc=0; SRC_URL="$QS_URL" env -u TGT_URL "$SH" "$SCRIPTS/pg_migrate.sh" audit --dry-run --out out6 >q2.txt 2>&1 || rc=$?
check "query-string password is masked in --dry-run" '[ "$rc" -eq 0 ] && ! grep "$SUPER_PW" q2.txt >/dev/null'

echo "== mask()"
# the masking helpers are one-line functions; load them from the script and call them directly
eval "$(grep -E '^mask(_stream)?\(\) ' "$SCRIPTS/pg_migrate.sh")"
m_eq() { [ "$(mask "$1")" = "$2" ]; }
check "URL user:password@ still masked" 'm_eq "postgresql://u:FIXTUREuserinfo0005@h/db" "postgresql://u:***@h/db"'
check "URL ?password= masked, other params kept" \
  'm_eq "postgresql://u@h:5432/db?sslmode=require&password=FIXTUREqs0004&application_name=x" "postgresql://u@h:5432/db?sslmode=require&password=***&application_name=x"'
check "URL ?password= as the first parameter" 'm_eq "postgresql://u@h/db?password=FIXTUREqs0006" "postgresql://u@h/db?password=***"'
check "conninfo password= masked" \
  'm_eq "host=db user=u password=FIXTUREconninfo0001 dbname=app" "host=db user=u password=*** dbname=app"'
check "conninfo password at the start" 'm_eq "password=FIXTUREconninfo0007 host=db" "password=*** host=db"'
check "conninfo quoted password with spaces and an escaped quote" \
  "m_eq \"password='FIXTURE quoted\\\\' 0002' host=db\" \"password=*** host=db\""
check "conninfo spaces around =" 'm_eq "host=db password = FIXTUREspaced0003 dbname=app" "host=db password=*** dbname=app"'
check "conninfo unquoted password containing & is masked whole" 'm_eq "password=FIXTUREamp&rest0009 host=db" "password=*** host=db"'
check "conninfo sslpassword= masked" 'm_eq "sslcert=c.crt sslpassword=FIXTUREsslkey0008 host=db" "sslcert=c.crt sslpassword=*** host=db"'
check "pg_dump option syntax \"password\" '...' masked" "m_eq \"    \\\"password\\\" 'FIXTUREopt0010''x',\" \"    \\\"password\\\" '***',\""
check "names that only contain 'password' are left alone" 'm_eq "host=db application_name=passwordless" "host=db application_name=passwordless"'

# ---------------------------------------------------------------- restore: event triggers, user mappings
# The documented restore is `restore --target-db app --role app_owner` as the admin user. A source event
# trigger aborts it ("Must be superuser"), and a user mapping either aborts it (its role is missing on the
# target) or recreates the stored credential there. Both are skipped by default.
echo "== restore: event triggers"
url_db() { printf '%s' "$ADMIN_URL" | sed -E "s#^([a-z]+://[^/]*)/[^?]*#\1/$1#"; }
psql "$ADMIN_URL" -X -q -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
SET client_min_messages TO error;
CREATE ROLE app_owner NOLOGIN;
GRANT app_owner TO CURRENT_USER;
CREATE ROLE ghost NOLOGIN;
CREATE DATABASE rs_evt;
CREATE DATABASE rs_um;
SQL
psql "$(url_db rs_evt)" -X -q -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE TABLE public.items (id bigserial PRIMARY KEY, name text);
INSERT INTO public.items (name) VALUES ('a'), ('b');
CREATE FUNCTION public.on_ddl() RETURNS event_trigger LANGUAGE plpgsql AS $$ BEGIN END $$;
CREATE EVENT TRIGGER watch_ddl ON ddl_command_start EXECUTE FUNCTION public.on_ddl();
SQL
psql "$(url_db rs_um)" -X -q -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE TABLE public.items (id bigserial PRIMARY KEY, name text);
CREATE EXTENSION postgres_fdw;
CREATE SERVER other_srv FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host 'other.invalid', dbname 'x');
CREATE USER MAPPING FOR PUBLIC SERVER other_srv OPTIONS (user 'x', password 'FIXTUREumpass0002');
CREATE USER MAPPING FOR ghost SERVER other_srv OPTIONS (user 'y', password 'FIXTUREumpass0003');
SQL
evt_count() { psql "$(url_db "$1")" -X -q -At -c 'SELECT count(*) FROM pg_event_trigger' 2>/dev/null || echo "?"; }
um_count() { psql "$(url_db "$1")" -X -q -At -c 'SELECT count(*) FROM pg_user_mappings' 2>/dev/null || echo "?"; }
mig() { env SRC_URL="$(url_db "$1")" TGT_URL="$ADMIN_URL" "$SH" "$SCRIPTS/pg_migrate.sh" "${@:2}"; }

rc=0; mig rs_evt dump --out d_evt >r0.txt 2>&1 || rc=$?
check "dump without --exclude-table-data exits 0" '[ "$rc" -eq 0 ]'
rc=0; mig rs_evt restore --out d_evt --target-db r_evt_role --role app_owner >r1.txt 2>&1 || rc=$?
check "restore --role app_owner exits 0 when the source has an event trigger" '[ "$rc" -eq 0 ]'
check "restore names the skipped event trigger in a NOTE" 'grep "NOTE" r1.txt | grep >/dev/null "watch_ddl"'
check "no event trigger on the target by default" '[ "$(evt_count r_evt_role)" = "0" ]'
check "restore still verifies OK" 'grep >/dev/null "VERIFY: OK" r1.txt'
rc=0; mig rs_evt restore --out d_evt --target-db r_evt_keep --keep-event-triggers >r2.txt 2>&1 || rc=$?
check "--keep-event-triggers without --role exits 0" '[ "$rc" -eq 0 ]'
check "--keep-event-triggers recreates the event trigger" '[ "$(evt_count r_evt_keep)" = "1" ]'
check "--keep-event-triggers warns about RDS major version upgrades" 'grep "WARN" r2.txt | grep >/dev/null "major version upgrade"'
rc=0; mig rs_evt restore --out d_evt --target-db r_evt_keep_role --keep-event-triggers --role app_owner >r3.txt 2>&1 || rc=$?
check "--keep-event-triggers with --role warns that it needs restore without --role" 'grep "WARN" r3.txt | grep >/dev/null "without --role"'

echo "== restore: user mappings"
rc=0; mig rs_um dump --out d_um1 >r4.txt 2>&1 || rc=$?
check "dump with user mappings exits 0" '[ "$rc" -eq 0 ]'
# the target cluster has no `ghost` role (as on a fresh RDS instance)
psql "$(url_db rs_um)" -X -q -v ON_ERROR_STOP=1 -c 'DROP USER MAPPING FOR ghost SERVER other_srv' >/dev/null
psql "$ADMIN_URL" -X -q -v ON_ERROR_STOP=1 -c 'DROP ROLE ghost' >/dev/null
rc=0; mig rs_um restore --out d_um1 --target-db r_um >r5.txt 2>&1 || rc=$?
check "restore exits 0 when a mapping's role is missing on the target" '[ "$rc" -eq 0 ]'
check "restore names the skipped user mappings in a NOTE" 'grep "NOTE" r5.txt | grep "ghost" | grep >/dev/null "public"'
check "no user mapping (and no stored credential) on the target by default" '[ "$(um_count r_um)" = "0" ]'
rc=0; mig rs_um dump --out d_um2 >r6.txt 2>&1 || rc=$?
rc=0; mig rs_um restore --out d_um2 --target-db r_um_keep --keep-user-mappings >r7.txt 2>&1 || rc=$?
check "--keep-user-mappings exits 0 when every mapping's role exists" '[ "$rc" -eq 0 ]'
check "--keep-user-mappings recreates the mapping" '[ "$(um_count r_um_keep)" = "1" ]'
check "--keep-user-mappings warns that stored credentials are recreated" 'grep "WARN" r7.txt | grep >/dev/null "credential"'
rc=0; mig rs_um restore --out d_um1 --target-db r_um_fail --keep-user-mappings >r8.txt 2>&1 || rc=$?
check "--keep-user-mappings with a mapping for a missing role fails (exit 1)" '[ "$rc" -eq 1 ]'
check "the failed restore's error output does not print the mapping password" '! grep "FIXTUREumpass" r8.txt >/dev/null'
check "no mapping password in restore output" '! cat r4.txt r5.txt r6.txt r7.txt | grep "FIXTUREumpass" >/dev/null'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
