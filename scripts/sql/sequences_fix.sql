-- sequences_fix.sql: setval() every serial/identity sequence to max(column)+1 (is_called=false).
-- Idempotent. Covers all user schemas.
-- Run with:  psql "$URL" -X -v ON_ERROR_STOP=1 -f sequences_fix.sql
SELECT format('SELECT setval(%L, COALESCE((SELECT MAX(%I) FROM %I.%I), 0) + 1, false);',
              pg_get_serial_sequence(format('%I.%I', n.nspname, t.relname), a.attname),
              a.attname, n.nspname, t.relname)
  FROM pg_class t
  JOIN pg_namespace n ON n.oid = t.relnamespace
  JOIN pg_attribute a ON a.attrelid = t.oid
 WHERE t.relkind IN ('r', 'p')
   AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'pgbouncer')
   AND n.nspname NOT LIKE 'pg_temp%'
   AND a.attnum > 0 AND NOT a.attisdropped
   AND pg_get_serial_sequence(format('%I.%I', n.nspname, t.relname), a.attname) IS NOT NULL
\gexec
