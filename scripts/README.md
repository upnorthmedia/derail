# Migration scripts

Helper scripts bundled with the `derail` skill. They inventory a Railway and/or Vercel
deployment, scan the codebase, move the Postgres database and file storage, load runtime secrets
into AWS Secrets Manager, and estimate the AWS bill. Terraform lives in `../assets/terraform`; these
scripts do the discovery and data movement around it.

## The secret-handling rule (applies to every script)

**No script ever prints a secret value to stdout or stderr.**

- Variable *values* are written only to files under `migration/.secrets/` (created with `umask 077`,
  files mode `600`). Every script that creates that directory also appends `migration/.secrets/` to
  the repository `.gitignore`.
- stdout, `SUMMARY.md`, `CODEBASE.md` and all JSON inventories contain **names, counts and
  classifications only**.
- Connection URLs are masked (`postgresql://user:***@host`) in all output, including `--dry-run`.
- Database URLs (`SRC_URL`, `TGT_URL`) and role passwords (`APP_RW_PASSWORD`, `APP_MIGRATE_PASSWORD`)
  are read from **environment variables**, never from arguments, so they do not land in shell history
  or `ps`. `pg_migrate.sh roles` reads the passwords *inside* psql with `\getenv`.
- `put_secrets.sh` parses `.env` files with `jq` directly into a `umask 077` temp file that is passed
  to the AWS CLI as `file://...` and deleted on exit; `--diff` compares key names (and whether values
  differ) without printing any value. It never prompts for a value: the env file is the only input.
- Railway bucket credentials are `eval`-ed inside a subshell that exits before the AWS-side sync runs.
- `railway_volume_to_s3.sh` moves files, not credentials: it relies on the already-logged-in Railway CLI
  (or your SSH key) and the AWS credential chain, and prints only paths, counts and sizes.
- `scan_codebase.py` classifies env var **names** (secret / public build-time / config / platform) and
  reports them in a table; `.env*` files contribute names only.
- `breach_check.sh` reads variable values into a `umask 077` temp dir only long enough to classify and
  fingerprint them. Fingerprints (`lib/fingerprint.sh`: sha256 over the value's base64, values under 8
  characters skipped) are the only value-derived thing it writes, to a mode-600 file you choose.

Claude (or a human) reading the inventories therefore never sees a credential. When a value is needed
(for example to seed Secrets Manager), it flows file -> tool, not through the conversation.

## Conventions

- Bash scripts: `set -euo pipefail`, `--help`, clear error when a CLI is missing, idempotent re-runs.
  Lint-clean with `shellcheck -S warning`.
- Python scripts: 3.9+, standard library only.
- Node script: Node 20+, deps in `package.json` (`npm install` in this directory), run with `tsx`.
- Default working tree layout (relative to the app repo root):

```
migration/
  inventory/railway/   SUMMARY.md, services.normalized.json, variables/*.json, raw/*.json, errors.log
  inventory/vercel/    SUMMARY.md, env/*.json, domains.txt, raw/*, errors.log
  inventory/codebase.json, CODEBASE.md
  db/                  preflight-*.txt, dump-<stamp>/ (pg_dump dir + counts/checksums), restore-*.log, LATEST
  .secrets/            railway.<service>.env, vercel.<env>.env, aws.<env>.env   (git-ignored, 0600)
  blob-manifest.ndjson
```

## Scripts

| Script | Purpose | Inputs | Output |
|---|---|---|---|
| `check_prereqs.sh` | Verify terraform (>= 1.11) or tofu, aws CLI v2 + credentials, docker buildx, pg_dump/pg_restore/psql major, railway CLI (>= 5.27.0, WARN below: `connect --tunnel-only` 5.27.0, `tcp-proxy` 5.15.0, 5.x subcommands) + vercel CLI (logged in), node >= 20, jq, git | `--pg-major 18`, `--no-aws`, `--no-railway`, `--no-vercel`, `--offline` (= all three `--no-*`; no network calls) | Pass/warn/fail table; prints AWS **account id and region only**. Exit 1 on hard failures (terraform, aws, jq). With `--no-aws`/`--offline` only terraform/tofu can fail hard; missing CLIs are WARN. |
| `railway_inventory.sh` | Export a Railway project/environment: status, environment config, services, domains, volumes, buckets, per-service variables (classified), `railway config pull` (`.railway/railway.ts`), Postgres HA/PgBouncer/PITR status, usage | `--project <id-or-name> --environment production --out migration/inventory/railway [--secrets-dir migration/.secrets]` | `SUMMARY.md` services table + variable names by class; raw JSON in `raw/`; values in `.secrets/railway.<service>.env`; all CLI failures in `errors.log` (script continues) |
| `vercel_inventory.sh` | Export a Vercel project: link, project inspect, `env ls` (Config vs Secret), `env pull` per environment, domains + DNS records, blob listing (if a token is available), copies `vercel.json` / `next.config.*` | `--project <name> --team <slug> [--repo .] --out migration/inventory/vercel` | `SUMMARY.md` with framework, node version, domains, crons, env names (Secret = cannot be exported, must be re-sourced), rewrites/redirects/headers, functions; pulled values in `.secrets/vercel.<env>.env` |
| `scan_codebase.py` | Static scan of the app repo: package manager, node version, framework, Next.js specifics (`output: 'standalone'` present/missing, edge routes, middleware/proxy, ISR/revalidate, next/image, cacheHandler), Payload adapters, auth/ORM/driver libs, **queue/worker libraries** (celery, rq, bullmq, bee-queue, graphile-worker, pg-boss, sidekiq -> separate ECS worker service) vs **in-process schedulers** (node-cron, croner, bree, APScheduler -> every replica fires), webhook SDKs + routes, Vercel imports, env var references classified **secret / public_buildtime / config / platform** (webhook URLs and datastore connection strings count as secrets), platform markers, hard-coded platform hostnames, **port detection** (Dockerfile `EXPOSE`, `CMD`/`ENTRYPOINT` `--port N`/`-p N`/`:N`, Procfile, railway `startCommand`, `uvicorn --port`, code literals; recommends `container_port`), health endpoints, crons, commands, tests, Dockerfile metadata. Security/storage findings: **DB TLS verification disabled** (`rejectUnauthorized: false`, `sslmode=no-verify/disable`, `ssl=false`, `PGSSLMODE=disable` -> verify-full with the RDS CA), **Twilio `validateRequest(req.url)`** (wrong URL behind CloudFront/ALB), **local filesystem writes** (`UPLOAD_DIR`, `/data`, `/mnt`, `fs.writeFile`, `createWriteStream`, `open(..., "w")`, `shutil.copyfileobj`, `aiofiles.open`, `Path().write_*` -> Railway volume -> S3/EFS decision). The "no Dockerfile" flag is platform-aware (Vercel built it / Railway Railpack-Nixpacks / neutral) | `python3 scan_codebase.py <repo> --out migration/inventory/codebase.json --md migration/inventory/CODEBASE.md [--json-only] [--vercel-node 24 \| --vercel-node migration/inventory/vercel/SUMMARY.md]` | JSON + Markdown with a prioritized **Migration flags** section and an env classification table. `--vercel-node` warns when `.nvmrc`/`engines.node` disagree with the Node version Vercel runs. Skips `node_modules/.git/.next/dist/build/...`; `.env*` files contribute names only |
| `pg_migrate.sh` + `sql/` | Railway Postgres -> RDS/Aurora. `preflight` (versions incl. `SHOW server_version_num`, size, extensions + availability on target, tables without PK), `dump` (`-Fd -j4 --compress=zstd --no-owner --no-privileges --no-subscriptions --no-publications --quote-all-identifiers`, `PGSSLMODE=require`, counts/checksums alongside; `--exclude-table-data PATTERN` repeatable, recorded in `meta.json` and skipped by verify), `restore` (create DB, pre-create extensions as master, `pg_restore -j --no-owner --no-privileges --no-comments [--role]` with a TOC filter for pre-created schemas/extensions, `ANALYZE`, counts/checksums/sequences/extensions diff -> `VERIFY: OK` / `MISMATCH`; prints a PostGIS `spatial_ref_sys` note and a hint when that table conflicts), `verify`, `roles` (renders `sql/app_roles.sql.tpl`). `audit` (read-only, `SRC_URL` only: roles and attributes, memberships, SECURITY DEFINER functions, triggers, event triggers, rules, extensions, schemas, object owners, FDW servers/user mappings, publications/subscriptions, live connections -> `<out>/db-audit-<stamp>.md` with a sign-off checklist; names, counts and definition hashes only, never row data, passwords, bodies or query text). `--pg-major-check` exits 1 before doing anything when `pg_dump` is older than the source server and names the client version to install | `SRC_URL`, `TGT_URL` env vars (required; `audit` needs `SRC_URL` only); `--target-db`, `--jobs`, `--role app_owner`, `--clean`, `--exclude-table-data 'spatial_ref_sys'`, `--pg-major-check`, `--dry-run`, `--out migration/db` | Dump directory, logs, `counts.*`/`sums.*` files, exit 1 on mismatch |
| `sql/rowcounts.sql`, `sql/checksums.sql` | Exact row counts and md5 per table (ordered by PK), all user schemas; **extension-owned tables** (`pg_depend` `deptype = 'e'`, e.g. PostGIS `spatial_ref_sys`) are excluded because `CREATE EXTENSION` recreates them; run both sides with `PGTZ=UTC` and diff | `psql "$URL" -X -At -f ...` | `schema.table\|value` lines |
| `sql/sequences_check.sql`, `sql/sequences_fix.sql` | Detect / fix sequences behind `max(column)` (needed after logical replication or partial loads); extension-owned sequences excluded from the check | `psql -f` | rows / `setval` |
| `sql/extensions.sql` | Installed extensions with version and schema | `psql -f` | `extname\|version\|schema` |
| `sql/app_roles.sql.tpl` | `app_owner` (NOLOGIN owner), `app_rw` (DML), `app_migrate` (DDL) with default privileges; passwords via `\getenv APP_RW_PASSWORD` / `APP_MIGRATE_PASSWORD` (psql 16+) | rendered by `pg_migrate.sh roles` | idempotent role setup |
| `blob_to_s3.ts` | Vercel Blob -> S3: cursor-paginated `list()`, `head()` for content type / cache headers, `HeadObject` size check (re-runnable), `p-limit` parallel copy, ndjson manifest, private stores via `BLOB_ACCESS=private`, `S3_PREFIX` | `BLOB_READ_WRITE_TOKEN`, `S3_BUCKET`, `S3_PREFIX`, `BLOB_ACCESS`, AWS credential chain; `--dry-run` (count only), `--prefix`, `--concurrency`, `--limit` | Objects in S3 with correct `Content-Type`; `migration/blob-manifest.ndjson` for the DB URL rewrite |
| `railway_bucket_to_s3.sh` | Railway Bucket (Tigris, S3-compatible) -> local staging -> S3, both legs `aws s3 sync` (incremental). Notes rclone for buckets larger than local disk | `--bucket <name> --target s3://bucket/prefix [--staging dir] [--delete] [--dry-run]` | Synced objects; counts |
| `railway_volume_to_s3.sh` | Railway **volume** (block storage mounted in a service, e.g. `/data`) -> local staging -> S3. `--method files` uses `railway volume files download <mount-path> <staging>` (newer CLI); `--method scp` uses `scp -r <service>@ssh.railway.com:<mount-path>/. <staging>` (needs working `railway ssh` for the service). Then `aws s3 sync` (Content-Type guessed from the extension; extensionless files are reported with a `--content-type` / `--metadata-directive REPLACE` note). Idempotent; writes a `path/bytes/sha256/content_type` manifest for rewriting DB paths | `--service <svc> [--mount-path /data] --target s3://bucket/prefix [--staging dir] [--method files\|scp] [--environment e] [--delete] [--dry-run] [-- extra sync args]` | Staged files, `<staging>.manifest.tsv`, count/size summary |
| `put_secrets.sh` | KEY=VALUE `.env` -> one JSON secret in Secrets Manager. The secret name is the one the Terraform secrets module creates: **`<project>-<env>/app`** (e.g. `lumen-prod/app`, output `app_secret_name`), not `<project>/<env>/app`. Writes via `put-secret-value --secret-string file://`; refuses `RAILWAY_*`/`VERCEL_*` and (by default) `NEXT_PUBLIC_*` keys; `--diff` compares names with the live secret. Reads the file only, never prompts. When `railway.burned.sha256` sits next to the env file (or `--burned-hashes FILE` is given), refuses any value whose fingerprint is in it, naming the key, never the value; `--allow-carryover KEY` for a non-secret false positive. No fingerprint file, no check | `--secret-name <project>-<env>/app --env-file [--region] [--dry-run] [--diff] [--create] [--burned-hashes FILE] [--allow-carryover KEY] [--no-burned-check]` | Key names, counts, new `VersionId` |
| `breach_check.sh` | "Am I exposed?" after Railway's 2026-10-21 breach. Walks every project / environment / service the CLI can see and writes a rotation checklist of variable **names**, grouped by priority (AI provider keys, cloud credentials, databases, payments, deploy tokens, session secrets, webhooks, other, references). Needs only the Railway CLI: no AWS, no migration. `--fingerprint FILE` records fingerprints of the current (exposed) values: run it **before** rotating. `--verify FILE` re-reads Railway and lists every variable still holding an exposed value (exit 1 if any) | `[--project ...] [--environment ...] [--out railway-exposure.md] [--fingerprint migration/.secrets/railway.burned.sha256] [--verify FILE]` | Markdown checklist (names only); fingerprint file (mode 600); CLI failures in `<out>.errors.log` |
| `estimate_cost.py` | Itemized monthly AWS estimate for budget / standard / production tiers with overrides (tasks, cpu/memory, RDS class, Multi-AZ, NAT, CloudFront plan, WAF, cache, ALB dedicated/shared, secrets, logs, Container Insights, worker tasks). Workers are priced on-demand unless `--worker-spot` (~70% off, unverified); a KMS CMK is added only with `--kms` (never implied by a tier); `--s3-gb` (S3 Standard $0.023/GB-mo + request/egress note), `--efs-gb` ($0.30/GB-mo), `--migration-host` (t4g.nano ~$3.07 + IPv4 $3.65 while it exists); `--region` other than us-east-1 prints a 5-20% note; `--railway-monthly` prints the delta; `--json` | flags | Table or JSON. Header states prices verified 2026-10-22 us-east-1 list prices and that data transfer is excluded |

## Typical order

```bash
scripts/check_prereqs.sh --pg-major 18          # add --offline when planning on a machine without AWS/Railway/Vercel access
# breach response only (values were on Railway on/after 2026-10-21): fingerprint BEFORE rotating anything
scripts/breach_check.sh --project my-app --fingerprint migration/.secrets/railway.burned.sha256 --out migration/BREACH-CHECK.md
scripts/railway_inventory.sh --project my-app --environment production
scripts/vercel_inventory.sh --project my-site --team my-team --repo .
python3 scripts/scan_codebase.py . --out migration/inventory/codebase.json --md migration/inventory/CODEBASE.md \
  --vercel-node migration/inventory/vercel/SUMMARY.md     # optional: compare with the Node version Vercel runs
python3 scripts/estimate_cost.py --tier standard --railway-monthly 48 [--worker-tasks 1 --worker-spot] [--kms] [--s3-gb 50]

# database (SRC_URL from `railway connect postgres --tunnel-only`, Railway CLI >= 5.27.0; TGT_URL from Terraform outputs + Secrets Manager)
export SRC_URL TGT_URL                      # set them with `read -rs`, never on the command line
scripts/pg_migrate.sh preflight --pg-major-check
scripts/pg_migrate.sh audit                  # read-only; review + sign off migration/db/db-audit-*.md before the final dump (breach mode: required)
scripts/pg_migrate.sh dump --jobs 4 [--exclude-table-data 'spatial_ref_sys']   # PostGIS: the extension refills it
APP_RW_PASSWORD=... APP_MIGRATE_PASSWORD=... scripts/pg_migrate.sh roles --target-db app
scripts/pg_migrate.sh restore --target-db app --role app_owner
scripts/pg_migrate.sh verify --target-db app

# files
(cd scripts && npm install)
BLOB_READ_WRITE_TOKEN=... S3_BUCKET=my-media S3_PREFIX=media/ npx tsx scripts/blob_to_s3.ts --dry-run
BLOB_READ_WRITE_TOKEN=... S3_BUCKET=my-media S3_PREFIX=media/ npx tsx scripts/blob_to_s3.ts
scripts/railway_bucket_to_s3.sh --bucket uploads --target s3://my-media/uploads
scripts/railway_volume_to_s3.sh --service api --mount-path /data --target s3://my-media/uploads --dry-run
scripts/railway_volume_to_s3.sh --service api --mount-path /data --target s3://my-media/uploads   # re-run before cutover

# secrets (compose migration/.secrets/aws.prod.env from the railway/vercel files, re-sourcing every Secret-type var).
# The secret name is <project>-<env>/app, as created by the Terraform secrets module (output app_secret_name).
scripts/put_secrets.sh --secret-name my-app-prod/app --env-file migration/.secrets/aws.prod.env --diff
scripts/put_secrets.sh --secret-name my-app-prod/app --env-file migration/.secrets/aws.prod.env
# breach response: refuses exposed values automatically (railway.burned.sha256 sits next to the env file);
# prove Railway itself no longer holds any exposed value
scripts/breach_check.sh --project my-app --verify migration/.secrets/railway.burned.sha256
```

## Tests

```bash
bash scripts/tests/test_breach_tools.sh                          # bash from PATH
BASH_UNDER_TEST=/bin/bash /bin/bash scripts/tests/test_breach_tools.sh   # macOS bash 3.2
bash scripts/tests/test_inventory_cli_compat.sh
bash scripts/tests/test_check_prereqs.sh
bash scripts/tests/test_pg_audit.sh                              # needs docker + psql; SKIPs without them
```

- `test_breach_tools.sh` runs `breach_check.sh`, `railway_inventory.sh` and `put_secrets.sh --dry-run`
  against a stand-in `railway` CLI and asserts that grouping, fingerprints, verification and the
  exposed-value guard work and that no fixture value appears in any output.
- `test_inventory_cli_compat.sh` checks that `railway_inventory.sh` exports variables on both the current
  CLI (`railway variable list`) and older ones that only have `railway variables` (4.16.1), and that on a
  4.16.1-like CLI it never invokes `domain list`, `service list` or `environment list`.
- `test_check_prereqs.sh` checks the Railway CLI version warning (old, boundary, new, unparseable).
- `test_pg_audit.sh` runs `pg_migrate.sh audit` and `restore` against a throwaway `postgres:17` container
  with planted roles, functions and triggers, and checks that no planted secret reaches any output.

All need jq; none touch Railway or AWS.

## Migrations: the tools image and the deploy workflow

Railway ran `preDeployCommand` on the new build before switching traffic. The AWS equivalent is in
`assets/github-workflows/deploy.yml`: build `:<sha>` (Dockerfile target `runner`) **and** `:<sha>-tools`
(target `tools`: full `node_modules` + source, what `payload migrate` / `drizzle-kit migrate` /
`prisma migrate deploy` / `npx auth@latest migrate` need and the standalone runner cannot run), then run
the tools image as a one-off ECS task from the Terraform-managed migration task definition, and only when
it exits 0 run `terraform apply -var image_tag=<sha>`. Python images have no separate tools target: set
`BUILD_TOOLS_IMAGE=false` and `MIGRATION_COMMAND="alembic upgrade head"`; the same image runs both.
All three Dockerfile templates bake the RDS CA bundle at `/app/global-bundle.pem`
(`RDS_CA_BUNDLE_PATH`) so `DATABASE_URL` can use `sslmode=verify-full`.

## Known limitations

- Railway and Vercel CLI JSON shapes change between versions. The inventory scripts parse defensively
  (`jq '... // empty'`, text fallbacks) and always keep the raw output so the gaps can be read by hand;
  fields they could not find are shown as `?`.
- Sealed Railway variables and Secret-type Vercel variables cannot be exported by any tool; the
  inventories list their names so they can be re-issued.
- `pg_migrate.sh restore` is re-runnable into a scratch database with `--clean`; without it a second
  run fails on existing tables (by design, to protect a live target).
- `estimate_cost.py` uses list prices for us-east-1 and excludes data transfer; treat it as +/-15%.
- `railway_inventory.sh` targets the current Railway CLI (5.x). It only runs a subcommand that
  `railway <cmd> --help` lists, because older CLIs read an unknown subcommand as an argument (4.16.1 takes
  `railway domain list` as "add the custom domain `list`"). On 4.16.1 the variable export still works
  (via `railway variables`), but `service list`, `domain list`, `environment config`/`list`, `bucket list`,
  `cron list`, `config pull`, `postgres ... status` and `usage projects` are skipped (logged as
  `skipped: not in this CLI` in `errors.log`): service names then come only from `railway status --json`
  and there is no `railway.ts`. Upgrade the CLI (`npm i -g @railway/cli`) before running the inventory.
- `railway_volume_to_s3.sh --method files` depends on `railway volume files download`, which exists only
  in newer Railway CLI releases; older CLIs must use `--method scp` (requires `railway ssh` to work for the
  service, i.e. a running deployment and an SSH key linked to the account).
- `breach_check.sh` cannot see sealed variables (the CLI cannot read them) or copies of a key outside
  Railway; the checklist says so. Its fingerprints only help if taken before rotation: a fingerprint of an
  already-rotated value protects nothing.
- `scan_codebase.py` pattern detections (TLS off, Twilio URL, filesystem writes) are regex-based and
  reviewed by hand: they point at files, they do not prove a problem.
