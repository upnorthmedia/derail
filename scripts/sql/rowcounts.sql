-- rowcounts.sql: exact row count per table (not n_live_tup estimates).
-- Run with:  psql "$URL" -X -At -f rowcounts.sql | sort
-- Output lines:  schema.table|count
-- Covers all user schemas; partitioned parents are counted once (partitions skipped).
-- Extension-owned tables (e.g. PostGIS spatial_ref_sys) are excluded: the extension recreates them.
SELECT format('SELECT %L || %L || count(*) FROM %I.%I',
              n.nspname || '.' || c.relname, '|', n.nspname, c.relname)
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r', 'p')
   AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'pgbouncer')
   AND n.nspname NOT LIKE 'pg_temp%'
   AND NOT c.relispartition
   -- extension-owned tables (pg_depend deptype 'e', e.g. PostGIS spatial_ref_sys, pg_stat_statements
   -- views) are created and populated by CREATE EXTENSION on the target, not by pg_restore: skip them
   -- so both sides compare like for like.
   AND NOT EXISTS (SELECT 1 FROM pg_depend d
                    WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
 ORDER BY 1
\gexec
