-- sequences_check.sql: sequences whose last_value is below the max of the column they feed.
-- A full pg_dump/pg_restore carries setval() so this should return 0 rows; it will NOT after
-- logical replication or --data-only partial loads. Fix with sequences_fix.sql.
-- Extension-owned sequences/tables (e.g. PostGIS) are excluded.
-- Run with:  psql "$URL" -X -At -f sequences_check.sql
-- Output lines:  schema.sequence|table|column|last_value|max_value
SELECT ps.schemaname || '.' || seq.relname AS sequence,
       tbl.relname AS "table",
       col.attname AS "column",
       coalesce(ps.last_value, 0) AS last_value,
       (xpath('/row/max/text()',
              query_to_xml(format('SELECT max(%I) FROM %I.%I', col.attname, ps.schemaname, tbl.relname),
                           false, true, '')))[1]::text::bigint AS max_value
  FROM pg_depend d
  JOIN pg_class seq ON seq.oid = d.objid AND seq.relkind = 'S'
  JOIN pg_class tbl ON tbl.oid = d.refobjid
  JOIN pg_attribute col ON col.attrelid = tbl.oid AND col.attnum = d.refobjsubid
  JOIN pg_sequences ps ON ps.sequencename = seq.relname
                      AND ps.schemaname = seq.relnamespace::regnamespace::text
 WHERE d.deptype IN ('a', 'i')
   -- skip sequences/tables owned by an extension (deptype 'e'): CREATE EXTENSION manages them
   AND NOT EXISTS (SELECT 1 FROM pg_depend e
                    WHERE e.classid = 'pg_class'::regclass AND e.objid IN (seq.oid, tbl.oid) AND e.deptype = 'e')
   AND coalesce(ps.last_value, 0) <
       coalesce((xpath('/row/max/text()',
                 query_to_xml(format('SELECT max(%I) FROM %I.%I', col.attname, ps.schemaname, tbl.relname),
                              false, true, '')))[1]::text::bigint, 0)
 ORDER BY 1;
