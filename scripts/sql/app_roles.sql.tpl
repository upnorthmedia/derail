-- app_roles.sql.tpl: least-privilege application roles on RDS/Aurora PostgreSQL.
-- Rendered by `pg_migrate.sh roles` (placeholders in {{...}}), then executed as the master user
-- against the application database. NO passwords live in this file: they are read from the
-- environment INSIDE psql with \getenv (psql 16+), so they never appear in argv, shell history
-- or any log. Required env: APP_RW_PASSWORD, APP_MIGRATE_PASSWORD.
--
-- Placeholders: {{DB_NAME}} {{APP_OWNER}} {{APP_RW}} {{APP_MIGRATE}} {{MASTER_USER}}
-- Idempotent: safe to re-run (roles are created only if missing; passwords are re-applied).
\set ON_ERROR_STOP on
\getenv app_rw_password APP_RW_PASSWORD
\getenv app_migrate_password APP_MIGRATE_PASSWORD
\if :{?app_rw_password}
\else
  \echo 'ERROR: APP_RW_PASSWORD is not set in the environment'
  \quit 1
\endif
\if :{?app_migrate_password}
\else
  \echo 'ERROR: APP_MIGRATE_PASSWORD is not set in the environment'
  \quit 1
\endif
\set QUIET on

-- owner role (NOLOGIN): owns schema objects; migrations run as a member of it
SELECT format('CREATE ROLE %I NOLOGIN', '{{APP_OWNER}}')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{{APP_OWNER}}') \gexec

-- runtime user: DML only
SELECT format('CREATE ROLE %I LOGIN', '{{APP_RW}}')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{{APP_RW}}') \gexec
ALTER ROLE "{{APP_RW}}" WITH LOGIN PASSWORD :'app_rw_password';

-- migration user: member of the owner role (creates/alters tables)
SELECT format('CREATE ROLE %I LOGIN IN ROLE %I', '{{APP_MIGRATE}}', '{{APP_OWNER}}')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{{APP_MIGRATE}}') \gexec
ALTER ROLE "{{APP_MIGRATE}}" WITH LOGIN PASSWORD :'app_migrate_password';
SELECT format('GRANT %I TO %I', '{{APP_OWNER}}', '{{APP_MIGRATE}}')
 WHERE NOT EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid JOIN pg_roles u ON u.oid = m.member
                    WHERE r.rolname = '{{APP_OWNER}}' AND u.rolname = '{{APP_MIGRATE}}') \gexec

-- master must be a member of the owner role so `pg_restore --role={{APP_OWNER}}` (SET ROLE) works
SELECT format('GRANT %I TO %I', '{{APP_OWNER}}', '{{MASTER_USER}}')
 WHERE NOT EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid JOIN pg_roles u ON u.oid = m.member
                    WHERE r.rolname = '{{APP_OWNER}}' AND u.rolname = '{{MASTER_USER}}') \gexec

ALTER DATABASE "{{DB_NAME}}" OWNER TO "{{APP_OWNER}}";
ALTER SCHEMA public OWNER TO "{{APP_OWNER}}";
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

GRANT CONNECT ON DATABASE "{{DB_NAME}}" TO "{{APP_RW}}", "{{APP_MIGRATE}}";
GRANT USAGE ON SCHEMA public TO "{{APP_RW}}";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "{{APP_RW}}";
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO "{{APP_RW}}";
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO "{{APP_RW}}";

-- future objects created by the owner (migrations) are usable by the runtime role
ALTER DEFAULT PRIVILEGES FOR ROLE "{{APP_OWNER}}" IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "{{APP_RW}}";
ALTER DEFAULT PRIVILEGES FOR ROLE "{{APP_OWNER}}" IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO "{{APP_RW}}";
ALTER DEFAULT PRIVILEGES FOR ROLE "{{APP_OWNER}}" IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO "{{APP_RW}}";

-- optional: IAM database authentication instead of the password (uncomment)
-- GRANT rds_iam TO "{{APP_RW}}";

\unset app_rw_password
\unset app_migrate_password
\echo roles ready: {{APP_OWNER}} (owner, NOLOGIN), {{APP_RW}} (runtime), {{APP_MIGRATE}} (migrations)
