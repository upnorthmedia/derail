# Changelog

## v1.0.0 (2026-10-23)

First tagged release. Everything since the initial public commit.

### Added

- **Breach mode** for Railway's environment-variable breach disclosed on 2026-10-21. The skill asks once
  whether values were on Railway on or after that date; if so, `references/breach-response.md` drives
  the work and ordinary migrations are unaffected.
  - `scripts/breach_check.sh`: walks every Railway project, environment and service the CLI can see and
    writes a names-only rotation checklist (AI provider keys first). Each variable whose provider is
    known notes whether old and new keys can be live together. `--fingerprint` records sha256
    fingerprints of current values before rotation; `--verify` lists any readable Railway variable that
    still holds an exposed value.
  - `put_secrets.sh` refuses any value whose fingerprint is in `railway.burned.sha256` next to the env
    file (or `--burned-hashes`), with `--allow-carryover` for false positives.
  - `migration/BREACH.md`, a per-provider rotation table (dual-key vs hard-cut), and session/auth
    secrets rotated at the cutover minute without leaving the leaked value in a previous-secrets list.
  - Runbook: the Railway TCP proxy is retired before the first rehearsal dump, and an optional canary
    credential sits in the old environment between cutover and decommissioning.
- **Keyless scorecard** at the top of every plan: long-lived secrets on the source platforms vs on AWS.
- `pg_migrate.sh audit`: read-only source database audit for sign-off before the final dump (roles and
  memberships, SECURITY DEFINER functions, triggers, event triggers, rules, extensions, schemas and
  owners, foreign servers and user mappings, replication objects, live connections). Names only.
- `check_prereqs.sh` warns when the Railway CLI is older than 5.27.0 (needed for
  `railway connect --tunnel-only`).
- `assets/github/dependabot.yml`: weekly updates for digest-pinned base images and workflow actions.
- Eval case `evals/railway-breach-nextjs-ai` (breach mode).
- Test suites under `scripts/tests/` (stand-in Railway CLI, real throwaway PostgreSQL), run on bash 3.2
  and 5 and in CI.

### Changed

- Renamed the skill and repository to **derail**.
- Dockerfiles pin base images by tag and digest; the `NODE_VERSION`/`PYTHON_VERSION` build args are gone
  (change the `FROM` line instead).
- `pg_migrate.sh restore` skips event triggers and foreign-server user mappings by default
  (`--keep-event-triggers`, `--keep-user-mappings`), temporarily grants `--role` USAGE on the
  foreign-data wrappers a dump's foreign servers need, creates every file under `--out` with mode 600,
  and adds `--out` to `.gitignore`.
- `railway_inventory.sh` uses `railway service list` instead of the deprecated `service status --all`,
  reads only the target environment from `status --json`, and works on 4.x CLIs (it skips subcommands
  the installed CLI does not list).

### Fixed

- `put_secrets.sh` and `pg_migrate.sh dump` crashed on macOS bash 3.2.
- Every Next.js Docker build failed (the secret mount needs Dockerfile syntax 1.10+).
- Node Docker builds failed for apps without dependencies, pnpm projects with approved build scripts,
  and Yarn 2+ (Plug'n'Play) projects.
- `pg_migrate.sh` printed passwords given as URL query parameters or conninfo `key=value` pairs.
- `pg_migrate.sh restore --role` aborted on a dump containing a foreign server.
- The `tools` image could not run a yarn or pnpm `MIGRATION_COMMAND` without downloading the package
  manager at migration time (Yarn 2+ also failed on its install state); Yarn 2+ `.yarnrc.yml` with
  `yarnPath`, plugins or `patch:` dependencies broke the build, and Yarn 2+ pruning failed on `patch:`.

### Known issues

- The breach-mode eval (`evals/railway-breach-nextjs-ai`) has not been benchmarked yet.
- Private npm registries work with npm and Yarn 2+ through the `NPM_TOKEN` build secret, but not with
  pnpm, which ignores environment variables in a project `.npmrc`.
