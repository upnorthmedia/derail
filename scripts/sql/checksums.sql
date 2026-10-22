-- checksums.sql: md5 over every row of every table, ordered by primary key so both sides hash
-- identically. Tables without a PK fall back to ordering by the full row text (slower, still
-- deterministic). Set PGTZ=UTC on BOTH sides (timestamptz text output depends on TimeZone).
-- Run with:  PGTZ=UTC psql "$URL" -X -At -f checksums.sql | sort
-- Output lines:  schema.table|md5
-- Extension-owned tables (e.g. PostGIS spatial_ref_sys) are excluded: the extension recreates them.
SELECT format(
  'SELECT %L || %L || md5(coalesce(string_agg(t::text, %L ORDER BY %s), %L)) FROM %I.%I t',
  n.nspname || '.' || c.relname, '|', '|',
  coalesce((SELECT string_agg(quote_ident(a.attname), ',' ORDER BY k.ord)
              FROM pg_index i
              JOIN unnest(i.indkey) WITH ORDINALITY k(attnum, ord) ON true
              JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
             WHERE i.indrelid = c.oid AND i.indisprimary), 't::text'),
  '', n.nspname, c.relname)
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
