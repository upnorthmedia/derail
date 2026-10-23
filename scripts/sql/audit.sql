-- audit.sql: read-only security inventory of the SOURCE database, for sign-off before the final dump.
-- pg_dump carries functions, triggers, rules, SECURITY DEFINER code and objects owned by extra roles
-- into the target as-is; this lists them so a person can confirm each one is the app's own.
-- Run by `pg_migrate.sh audit`; by hand:  psql "$SRC_URL" -X -q -v ON_ERROR_STOP=1 -f audit.sql
--
-- Prints names, attributes and counts only: no row data, no passwords (pg_roles.rolpassword,
-- pg_user_mappings.umoptions and pg_subscription.subconninfo are never selected), no function bodies
-- (only the length and a 12-hex-char SHA-256 prefix of pg_get_functiondef(), so two runs can be diffed),
-- no query text, no setting values (names only). Output is Markdown with psql tables in ~~~ fences.
-- Needs PostgreSQL 11+. Fullest results when run as a superuser (Railway's `postgres` user is one);
-- otherwise other sessions' client_addr/state are hidden by PostgreSQL.
\set ON_ERROR_STOP on
SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY;
\pset pager off
\pset null '-'
\pset footer on

\echo '## 0. Context'
\echo '~~~'
SELECT current_database() AS database,
       current_user AS audited_as,
       (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) AS audited_as_superuser,
       current_setting('server_version') AS server_version,
       to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || 'Z' AS taken_at;
\echo '~~~'

\echo '## 1. Roles (all non-system roles, login roles first)'
\echo '~~~'
SELECT r.rolname AS role,
       r.rolcanlogin AS login,
       r.rolsuper AS superuser,
       r.rolcreaterole AS createrole,
       r.rolcreatedb AS createdb,
       r.rolbypassrls AS bypassrls,
       r.rolreplication AS replication,
       r.rolconnlimit AS connlimit,
       r.rolvaliduntil AS valid_until
  FROM pg_roles r
 WHERE r.rolname !~ '^pg_'
 ORDER BY r.rolcanlogin DESC, r.rolname;
\echo '~~~'

\echo '## 2. Role memberships (member -> granted role)'
\echo '~~~'
SELECT m.rolname AS member,
       r.rolname AS member_of,
       am.admin_option,
       g.rolname AS grantor
  FROM pg_auth_members am
  JOIN pg_roles r ON r.oid = am.roleid
  JOIN pg_roles m ON m.oid = am.member
  LEFT JOIN pg_roles g ON g.oid = am.grantor
 WHERE m.rolname !~ '^pg_'
 ORDER BY 1, 2;
\echo '~~~'

\echo '## 3. Per-role / per-database settings (names only; e.g. search_path, session_preload_libraries)'
\echo '~~~'
SELECT COALESCE(d.datname, '(all databases)') AS database,
       COALESCE(r.rolname, '(all roles)') AS role,
       string_agg(split_part(c, '=', 1), ', ' ORDER BY c) AS settings
  FROM pg_db_role_setting s
  LEFT JOIN pg_database d ON d.oid = s.setdatabase
  LEFT JOIN pg_roles r ON r.oid = s.setrole
 CROSS JOIN LATERAL unnest(s.setconfig) AS c
 GROUP BY 1, 2
 ORDER BY 1, 2;
\echo '~~~'

\echo '## 4. SECURITY DEFINER functions and procedures (run with the owner''s privileges)'
\echo '~~~'
SELECT n.nspname AS schema,
       p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS function,
       pg_get_userbyid(p.proowner) AS owner,
       l.lanname AS language,
       COALESCE(x.extname, '-') AS extension,
       COALESCE((SELECT string_agg(split_part(c, '=', 1), ', ' ORDER BY c) FROM unnest(p.proconfig) AS c), '-') AS set_options,
       length(pg_get_functiondef(p.oid)) AS def_len,
       left(encode(sha256(convert_to(pg_get_functiondef(p.oid), 'UTF8')), 'hex'), 12) AS def_sha256
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l ON l.oid = p.prolang
  LEFT JOIN pg_depend dep ON dep.classid = 'pg_proc'::regclass AND dep.objid = p.oid AND dep.deptype = 'e'
  LEFT JOIN pg_extension x ON x.oid = dep.refobjid
 WHERE p.prosecdef
   AND p.prokind IN ('f', 'p')
   AND n.nspname NOT IN ('pg_catalog', 'information_schema')
 ORDER BY 1, 2;
\echo '~~~'

\echo '## 5. Triggers on user tables (excluding internal FK triggers) and the function each calls'
\echo '~~~'
SELECT n.nspname || '.' || c.relname AS "table",
       t.tgname AS trigger,
       CASE t.tgenabled WHEN 'O' THEN 'enabled' WHEN 'D' THEN 'disabled'
                        WHEN 'R' THEN 'replica' WHEN 'A' THEN 'always' END AS enabled,
       fn.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS function,
       pg_get_userbyid(p.proowner) AS function_owner,
       p.prosecdef AS security_definer,
       l.lanname AS language,
       left(encode(sha256(convert_to(pg_get_functiondef(p.oid), 'UTF8')), 'hex'), 12) AS def_sha256
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_proc p ON p.oid = t.tgfoid
  JOIN pg_namespace fn ON fn.oid = p.pronamespace
  JOIN pg_language l ON l.oid = p.prolang
 WHERE NOT t.tgisinternal
   AND n.nspname NOT IN ('pg_catalog', 'information_schema')
 ORDER BY 1, 2;
\echo '~~~'

\echo '## 6. Event triggers (fire on DDL in the whole database)'
\echo '~~~'
SELECT e.evtname AS event_trigger,
       e.evtevent AS event,
       pg_get_userbyid(e.evtowner) AS owner,
       CASE e.evtenabled WHEN 'O' THEN 'enabled' WHEN 'D' THEN 'disabled'
                         WHEN 'R' THEN 'replica' WHEN 'A' THEN 'always' END AS enabled,
       fn.nspname || '.' || p.proname || '()' AS function,
       p.prosecdef AS security_definer,
       COALESCE(array_to_string(e.evttags, ', '), '-') AS tags,
       left(encode(sha256(convert_to(pg_get_functiondef(p.oid), 'UTF8')), 'hex'), 12) AS def_sha256
  FROM pg_event_trigger e
  JOIN pg_proc p ON p.oid = e.evtfoid
  JOIN pg_namespace fn ON fn.oid = p.pronamespace
 ORDER BY 1;
\echo '~~~'

\echo '## 7. Rules on tables (rewrite rules other than views)'
\echo '~~~'
SELECT r.schemaname || '.' || r.tablename AS "table",
       r.rulename AS rule,
       left(encode(sha256(convert_to(r.definition, 'UTF8')), 'hex'), 12) AS def_sha256
  FROM pg_rules r
 WHERE r.schemaname NOT IN ('pg_catalog', 'information_schema')
 ORDER BY 1, 2;
\echo '~~~'

\echo '## 8. Installed extensions'
\echo '~~~'
SELECT e.extname AS extension,
       e.extversion AS version,
       n.nspname AS schema,
       pg_get_userbyid(e.extowner) AS owner
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
 ORDER BY 1;
\echo '~~~'

\echo '## 9. Schemas and owners (excluding pg_* and information_schema)'
\echo '~~~'
SELECT n.nspname AS schema,
       pg_get_userbyid(n.nspowner) AS owner
  FROM pg_namespace n
 WHERE n.nspname !~ '^pg_'
   AND n.nspname <> 'information_schema'
 ORDER BY 1;
\echo '~~~'

\echo '## 10. Object owners (relations and functions in user schemas, by owner and kind)'
\echo '~~~'
SELECT o.owner, o.kind, count(*) AS objects
  FROM (SELECT pg_get_userbyid(c.relowner) AS owner,
               CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned table' WHEN 'v' THEN 'view'
                              WHEN 'm' THEN 'materialized view' WHEN 'S' THEN 'sequence'
                              WHEN 'f' THEN 'foreign table' ELSE c.relkind::text END AS kind
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
           AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
        UNION ALL
        SELECT pg_get_userbyid(p.proowner), 'function'
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema') AS o
 GROUP BY 1, 2
 ORDER BY 1, 2;
\echo '~~~'

\echo '## 11. Foreign data wrappers, foreign servers, user mappings (names only; mapping options hold credentials and are not read)'
\echo '~~~'
SELECT 'wrapper' AS kind, w.fdwname AS name, '-' AS server, pg_get_userbyid(w.fdwowner) AS owner_or_user
  FROM pg_foreign_data_wrapper w
UNION ALL
SELECT 'server', s.srvname, '-', pg_get_userbyid(s.srvowner)
  FROM pg_foreign_server s
UNION ALL
SELECT 'user mapping', '-', um.srvname, um.usename
  FROM pg_user_mappings um
 ORDER BY 1, 2, 3, 4;
\echo '~~~'

\echo '## 12. Publications and subscriptions (logical replication; connection strings are not read)'
\echo '~~~'
SELECT 'publication' AS kind,
       p.pubname AS name,
       pg_get_userbyid(p.pubowner) AS owner,
       CASE WHEN p.puballtables THEN 'all tables'
            ELSE (SELECT count(*) FROM pg_publication_tables pt WHERE pt.pubname = p.pubname)::text || ' table(s)' END AS detail
  FROM pg_publication p
UNION ALL
SELECT 'subscription', s.subname, pg_get_userbyid(s.subowner),
       CASE WHEN s.subenabled THEN 'enabled' ELSE 'disabled' END
  FROM pg_subscription s
 WHERE s.subdbid = (SELECT oid FROM pg_database WHERE datname = current_database())
 ORDER BY 1, 2;
\echo '~~~'

\echo '## 13. Client connections right now, all databases (grouped; this audit session excluded; no query text)'
\echo '~~~'
SELECT a.datname AS database,
       a.usename AS "user",
       COALESCE(NULLIF(a.application_name, ''), '-') AS application_name,
       COALESCE(host(a.client_addr), '-') AS client_addr,
       COALESCE(a.state, '-') AS state,
       count(*) AS sessions,
       to_char(min(a.backend_start) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || 'Z' AS oldest_since
  FROM pg_stat_activity a
 WHERE a.backend_type = 'client backend'
   AND a.pid <> pg_backend_pid()
 GROUP BY 1, 2, 3, 4, 5
 ORDER BY (COALESCE(a.state, '-') = 'idle'), 1, 2, 3, 4;
\echo '~~~'
