# TODO

## Open

- [confirmed] 2026-10-22: `pg_migrate.sh restore --role app_owner` aborts on any foreign server in the dump ("permission denied for foreign-data wrapper postgres_fdw", reproduced on postgres:17). Needs a decision: grant USAGE on the FDW to the role before pg_restore, skip SERVER entries by default, or document restore without `--role` for FDW users.
- [confirmed] 2026-10-22: `railway service status --all` is deprecated in Railway CLI 5.71.0 ("Please use railway service list instead"). `railway_inventory.sh` still calls it; it works today but may be removed.
- [investigate] 2026-10-22: On Railway CLI 4.16.1 `railway_inventory.sh` finds service names only from `railway status --json`; the jq fallback assumes `services.edges[].node.name`, not checked against real 4.16.1 output.
- [investigate] 2026-10-22: `pg_migrate.sh` writes `restore-<stamp>.log` with pg_restore's failing command verbatim (with `--keep-user-mappings`, a mapping password). Consider mode 600 for logs in `--out`, like the dump directory that already holds the same value.
- [investigate] 2026-10-22: Yarn 2+ tools image: a `MIGRATION_COMMAND` that calls yarn (e.g. `yarn prisma migrate deploy`) likely fails because Yarn's install state is not in the image; `npx`/`npm run` work. Not tested.
- [investigate] 2026-10-22: Node Dockerfiles copy `.npmrc` but not `.yarnrc.yml`, so Yarn 2+ private registry settings are not applied in the deps stage. Copying it blindly breaks projects whose `yarnPath` points into `.yarn/releases`.
- [optimization] 2026-10-22: `breach_check.sh` could print a per-key "dual-key: yes/grace/no" hint from the `references/breach-response.md` section 4 table. Skipped for I-04 because the current groups mix providers with different rules.
- [investigate] 2026-10-22: The eval `evals/railway-breach-nextjs-ai` has not been run yet (`claude plugin eval . --case railway-breach-nextjs-ai --allow-tools Write,Edit,Bash --scaffold`). Run it with and without the skill and tune ambiguous graders.

## Fixed on branch `readme-railway-breach-framing` (clear once merged)

- Session/auth secrets kept "identical through cutover" after the Railway breach (breach mode, e9a2dc8).
- I-04 rotation order per provider (fbd88d6). I-05 source DB audit (10c629c) and restore skips for event triggers and user mappings (11d7557). I-06 TCP proxy retired early and I-09 canary (dc50228). I-07 digest-pinned base images (f65b1ae).
- `railway_inventory.sh` on Railway CLI 4.16.1: `variables` fallback and no misparsed `domain list` / `service list` calls (dd131ec).
- Pre-existing bugs found on the way: `put_secrets.sh` and `pg_migrate.sh dump` crashed on macOS bash 3.2; every Next.js Docker build failed (secret mount needed Dockerfile syntax 1.10); npm no-deps, pnpm build approvals and Yarn 2+ Docker builds failed (9c1b4a9); `pg_migrate.sh` did not mask query-string passwords (5674a79).
