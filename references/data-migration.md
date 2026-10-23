# Data migration: PostgreSQL, files, and verification

Verified 2026-10-22 against docs.railway.com, docs.aws.amazon.com (RDS/Aurora/DMS), postgresql.org,
vercel.com/docs, payloadcms.com. Scripts: `scripts/pg_migrate.sh`, `scripts/sql/*`,
`scripts/blob_to_s3.ts`, `scripts/railway_bucket_to_s3.sh`.

## Contents
1. Version and extension compatibility
2. Dump and restore (the default path)
3. Minimal-downtime options and the decision rule
4. Roles and least privilege on RDS
5. Files: Vercel Blob / Railway buckets / volumes -> S3 (or EFS)
6. Verification
7. Other engines (Redis, MySQL, Mongo)

## 1. Compatibility

- PostgreSQL 18 is GA on RDS (Nov 2025) and Aurora (June 2026); 18.6 current. **Target the same major
  as the source.** `pg_dump` refuses to dump a server newer than itself, and loading into an older
  server is "not guaranteed" (PG18-only DDL such as `GENERATED ... VIRTUAL` breaks it). Install
  matching client tools: `postgresql-client-18` (apt PGDG) / `brew install libpq`.
- Check the region: `aws rds describe-db-engine-versions --engine postgres --query 'DBEngineVersions[?starts_with(EngineVersion,`18`)].EngineVersion'`.
- Extensions on RDS PG 18: pgvector 0.8.2, pg_trgm, uuid-ossp, pgcrypto, citext, hstore, PostGIS 3.6,
  pg_cron 1.6 (custom parameter group + reboot), pg_partman, pglogical, pgaudit. **No TimescaleDB.**
  Source inventory: `SELECT extname, extversion FROM pg_extension;` (`scripts/sql/extensions.sql`).
  Trusted extensions can be created by the app owner; PostGIS/pg_cron need the master user.
- RDS master user is `rds_superuser`, **not** a superuser: restore with `--no-owner --no-privileges`
  (both dump and restore) and `--no-comments` (kills "must be owner of extension plpgsql").
- pg_dump 18 does not dump optimizer statistics by default: run `ANALYZE` after every restore.
- RDS PG 15+ enforces TLS; use `sslmode=verify-full&sslrootcert=global-bundle.pem` for the target.

## 2. Dump and restore

```bash
# Source: SSH tunnel (preferred; no public exposure, no egress billing). Needs Railway CLI >= 5.27.0
# (4.x has no --tunnel-only; `railway --version`)
railway connect postgres --tunnel-only            # prints local host/port/password; keep running
export SRC_URL='postgresql://postgres:<pw>@localhost:<port>/railway'
# Target: RDS master, from a machine that can reach the private subnet (SSM port-forward / CloudShell
# in the VPC / a one-off ECS task) or temporarily from the laptop via a bastion.
export TGT_URL='postgresql://postgres:<master-pw>@<endpoint>:5432/postgres?sslmode=verify-full&sslrootcert=global-bundle.pem'

scripts/pg_migrate.sh preflight --pg-major-check   # versions (fails early if pg_dump < server major), size, extensions, tables without PK
scripts/pg_migrate.sh dump                          # -Fd -j4 zstd --no-owner --no-privileges --no-subscriptions --no-publications
#   PostGIS: add --exclude-table-data spatial_ref_sys (the extension recreates those rows on the target)
scripts/pg_migrate.sh roles --target-db app         # creates app_owner / app_migrate / app_rw (passwords from env, never echoed)
scripts/pg_migrate.sh restore --target-db app --role app_owner   # creates DB + extensions, pg_restore -j4 --no-comments, ANALYZE, verifies
scripts/pg_migrate.sh verify --target-db app        # counts + checksums both sides (extension-owned tables excluded)
```

Where it runs: the RDS endpoint is private. Options: the optional `migration_host` (SSM-only EC2 in the
VPC with the matching PostgreSQL client; `enable_migration_host = true` for the window, false after),
CloudShell with VPC access, or an SSM port-forward from a laptop through that host
(`terraform output migration_host_port_forward_commands`). Dumping from Railway over the SSH tunnel
works from wherever `railway` CLI runs; move the dump directory to the host with `aws s3 cp` to a
private staging prefix and delete it afterwards.

*(Breach mode only)* The Postgres password and `DATABASE_PUBLIC_URL` were exposed, and the TCP proxy
makes them usable from anywhere on the internet. Before the first rehearsal dump: rotate the password
(`references/breach-response.md` section 6), then delete the proxy so the database is reachable only
through the tunnel above. First confirm nothing outside Railway still uses `DATABASE_PUBLIC_URL` (CI
jobs, BI tools, local clients; check the inventory and `CODEBASE.md`). Then
`railway tcp-proxy list --service <postgres>` and `railway tcp-proxy delete <id>` (CLI >= 5.15.0), or
remove it in the dashboard under the service's Settings > Networking. `railway connect` tunnels over SSH
when the service has no proxy. If a dump cannot use the tunnel, or you run logical replication (section
3), re-create the proxy for that window only (`railway tcp-proxy create --port 5432 --service <postgres>`;
read the new domain and port from `tcp-proxy list`) and delete it when the window closes.

Flag rationale: directory format is the only one that supports parallel `--jobs`; `--no-owner
--no-privileges` strip Railway role references; `--no-subscriptions --no-publications` avoid dragging
replication objects; `--quote-all-identifiers` for safety; large objects are included by default. The
dump is a consistent snapshot, but writes after it starts are lost: stop writes first for the final run.

Expected benign errors with the RDS master: `must be owner of extension plpgsql` (use `--no-comments`),
`role "postgres" does not exist` (you forgot `--no-owner` on one side), `permission denied to create event
trigger` (rare; drop from the TOC with `pg_restore -l/-L`).

Timing for a 5 GB database: dump 2-5 min, restore `-j4` 3-8 min, verify 2 min. Rehearse once into a
scratch database (`--target-db app_rehearsal`) to get the real number, and run the app against the rehearsal
copy before cutover day. Where to run it: a laptop over the tunnel is fine for < 10 GB; for bigger
databases run from CloudShell/EC2/one-off ECS task in the target region.

## 3. Minimal-downtime options

| Size | Tolerable write-downtime | Choice |
|---|---|---|
| < 10 GB (typical Railway app) | >= 15 min | Dump/restore in a window (section 2). Nothing to configure on Railway. |
| 10-100 GB | >= 1-2 h | Dump/restore with `-j8` from a host in the target region; or logical replication if the window hurts. |
| any | < 5 min | Native logical replication, rehearsed. |
| > 100 GB or write-heavy | any | Logical replication; DMS only if the source cannot run `wal_level=logical`. |

**Native logical replication from Railway** is officially supported: on Railway
`ALTER SYSTEM SET wal_level = 'logical';` then restart the Postgres service (Railway's `postgres` role is
a real superuser). Create a replication role and `CREATE PUBLICATION aws_pub FOR ALL TABLES;`
(tables without a PK need `REPLICA IDENTITY FULL`). Load the schema into RDS with a `--schema-only`
dump, then as the RDS master `CREATE SUBSCRIPTION aws_sub CONNECTION 'host=<region>.proxy.rlwy.net
port=<port> dbname=railway user=repl password=... sslmode=require' PUBLICATION aws_pub;`. The RDS
instance needs an outbound route to Railway's public TCP proxy (NAT on the private subnets, or a
publicly accessible instance during migration). Cutover: stop writes, wait for lag 0, **resync
sequences** (not replicated), flip, `DROP SUBSCRIPTION` (an orphaned slot fills Railway's volume).
Limitations: no DDL, no sequences, no large objects. *(Breach mode only)* The proxy stays up for the
whole replication period, so create the replication role after the password rotation, give it a fresh
password, and delete the proxy right after `DROP SUBSCRIPTION` at cutover.

**AWS DMS**: works in principle (self-managed PG source over the proxy, SSL `require`, needs a superuser
for CDC) but adds a replication instance, does not migrate sequences, and PG 17/18 sources are not
listed as tested. Native logical replication does the same job with fewer parts.

## 4. Roles

`scripts/sql/app_roles.sql.tpl`: `app_owner` (NOLOGIN, owns schema; migrations run as a member of it),
`app_migrate` (LOGIN, member of app_owner), `app_rw` (LOGIN, DML only, default privileges granted).
`GRANT app_owner TO postgres` so the master can `pg_restore --role app_owner`. The app secret holds
`DATABASE_URL` for `app_rw` (runtime) and `DATABASE_MIGRATE_URL` for `app_migrate` if migrations run
in CI. Nothing from Railway (`postgres` password, `DATABASE_PUBLIC_URL`) survives the migration.

Connection budget: `tasks x pool.max + migrations + humans < 0.8 x max_connections`
(t4g.micro ~80-110, t4g.small ~190, t4g.medium ~400). Session features (LISTEN/NOTIFY, advisory locks,
`SET`) work on direct RDS; RDS Proxy would pin on them and costs ~$22/mo, so skip it.

## 5. Files

**Vercel Blob -> S3** (`scripts/blob_to_s3.ts`): `list()` pagination, `head()` per blob for
`contentType`/`cacheControl` (not in list results), streaming upload with `@aws-sdk/lib-storage`,
HeadObject size check for idempotent re-runs, manifest ndjson for the URL rewrite, `BLOB_ACCESS=private`
for private stores. The S3 key is `S3_PREFIX + pathname`. Check `vercel blob list` first: Payload's
Blob adapter already stores pathnames as `media/<filename>` (collection prefix included), so
`S3_PREFIX` is **empty** in that case; only set it when pathnames lack the prefix the S3 adapter expects.
Run it once days before cutover and once inside the window. Needs `BLOB_READ_WRITE_TOKEN`.

**URL rewrite** after the final restore: find columns (`information_schema.columns` where name matches
`url|src|image|file`) and `UPDATE ... SET url = regexp_replace(url, '^https://[a-z0-9]+\.(public|private)\.blob\.vercel-storage\.com/', 'https://<media-host>/<prefix>/')`;
rich-text JSONB via `replace(content::text, ...)::jsonb`. Payload regenerates `url` from `filename` +
prefix on read, but copies in rich text, SEO fields and external systems do not update themselves.

**Railway bucket -> S3** (`scripts/railway_bucket_to_s3.sh`): `eval "$(railway bucket credentials -b
<name>)"` then `aws s3 sync --endpoint-url "$AWS_ENDPOINT_URL" s3://$AWS_S3_BUCKET_NAME ./staging` and
`aws s3 sync ./staging s3://<new-bucket>/`; rclone with two remotes for large buckets. Railway buckets
have no versioning/lifecycle to carry over.

**Railway volume** (`scripts/railway_volume_to_s3.sh --service <svc> --mount-path /data --target s3://...`,
methods `files` = `railway volume files download`, `scp` = `scp -r <svc>@ssh.railway.com:<path>`; syncs
to S3 with a manifest). Decide: uploads directory -> S3 (refactor to the S3
adapter); SQLite -> RDS (or EFS single-task stopgap); caches -> nothing; software that must see a POSIX
directory across tasks (Ghost, Gitea, Directus local) -> EFS with an access point, transit encryption,
`efsVolumeConfiguration` in the task definition (~$0.30/GB-mo vs S3 $0.023).

**S3 + CloudFront OAC** (`s3_media` module): private bucket, Block Public Access on, OAC bucket policy
with `AWS:SourceArn` = distribution, versioning, lifecycle. Wrong `Content-Type` at upload is the
classic symptom of a bad copy (images download as octet-stream).

## 6. Verification (`scripts/sql/`)

`rowcounts.sql` (exact counts per table via `\gexec`), `checksums.sql` (md5 of each table ordered by
PK; set `PGTZ=UTC` on both sides), `sequences_check.sql` / `sequences_fix.sql` (serial/identity columns
whose sequence is behind `MAX(col)`), `extensions.sql`. `pg_migrate.sh verify` diffs source vs target
and exits non-zero on any mismatch. Also smoke-test as `app_rw`: one SELECT, one INSERT, and check
`has_table_privilege` across all tables.

## 7. Other engines

- **Redis -> ElastiCache Valkey**: usually cache/session data; let it rebuild. If data must move,
  `redis-cli --rdb` through the tunnel and `redis-cli --pipe` into Valkey (needs TLS + AUTH).
- **MySQL -> RDS MySQL**: `mysqldump --single-transaction --set-gtid-purged=OFF` via tunnel; `mysql <` into RDS.
- **MongoDB -> DocumentDB or Atlas**: `mongodump` via tunnel; DocumentDB lacks some operators, test
  the app first or use Atlas on AWS.
