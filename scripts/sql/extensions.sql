-- extensions.sql: installed extensions with version and schema (run on BOTH sides and diff).
-- pg_migrate.sh uses this list to pre-create extensions on the target before pg_restore
-- (RDS: the master user has rds_superuser; extensions must be in rds.extensions allow-list).
-- Run with:  psql "$URL" -X -At -f extensions.sql
-- Output lines:  extname|extversion|schema
SELECT e.extname || '|' || e.extversion || '|' || n.nspname
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
 WHERE e.extname <> 'plpgsql'
 ORDER BY 1;
