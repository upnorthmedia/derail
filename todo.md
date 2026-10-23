# TODO

## Open

- [investigate] 2026-10-22: The eval `evals/railway-breach-nextjs-ai` has no complete benchmark. The first with-skill run (2026-10-22) hit the old 60-turn limit while still writing the package; the case now allows 150 turns and an hour (907f4c0). Run it with and without the skill and tune ambiguous graders.
- [investigate] 2026-10-23: Confirm on a real RDS/Aurora instance that the master user can `GRANT USAGE ON FOREIGN DATA WRAPPER postgres_fdw` (an AWS Database Blog post says yes, the User Guide is silent). `pg_migrate.sh restore --role` now WARNs with the fallback if the grant does not take effect.
- [investigate] 2026-10-23: `breach_check.sh` rotation notes cover only the 16 credential types in `references/breach-response.md` section 4; other AI providers in the "AI provider keys" group (Groq, Mistral, Gemini, ...) have no verified rotation facts yet.
- [confirmed] 2026-10-23: pnpm private registries: pnpm 10.34.2+/11.5.3+ ignores `${NPM_TOKEN}` in a project `.npmrc` (GHSA-3qhv-2rgh-x77r, https://pnpm.io/npmrc; reproduced with pnpm 12.15.0), so the Dockerfiles' `NPM_TOKEN` build secret does not reach pnpm installs. Options: a user-level npmrc as a file secret, `PNPM_CONFIG_NPMRC_AUTH_FILE`, or document as unsupported (verify each before choosing).
- [optimization] 2026-10-23: Node Dockerfiles: Yarn 2+ installs have no BuildKit cache mount (global cache `/root/.yarn/berry/cache`), and the prod-deps `yarn workspaces focus` re-downloads every package; a cache mount on both RUNs would cut build time and registry traffic.
- [optimization] 2026-10-23: Yarn 4 prints YN0050 for `yarn install --frozen-lockfile` (deprecated in favour of `--immutable`); harmless, but the yarn branch could pick the flag by Yarn major.
- [investigate] 2026-10-23: Yarn 2/3, monorepo workspaces, URL-fetched Yarn plugins and a real private registry (npm, GitHub Packages) were not build-tested with the Node Dockerfiles; only Yarn 4.18.1 and a throwaway local registry were.
- [investigate] 2026-10-23: Commits 9bf18b5 and 5674a79 still hold credential-shaped test fixture literals (fake values) in history; the tree is clean for gitleaks and the CI secrets scan. A `.gitleaksignore` with their fingerprints would stop history scanners from flagging them.

## Fixed on branch `readme-railway-breach-framing` (clear once merged)

- Session/auth secrets kept "identical through cutover" after the Railway breach (breach mode, e9a2dc8).
- I-04 rotation order per provider (fbd88d6). I-05 source DB audit (10c629c) and restore skips for event triggers and user mappings (11d7557). I-06 TCP proxy retired early and I-09 canary (dc50228). I-07 digest-pinned base images (f65b1ae).
- `railway_inventory.sh` on Railway CLI 4.16.1: `variables` fallback and no misparsed `domain list` / `service list` calls (dd131ec).
- Pre-existing bugs found on the way: `put_secrets.sh` and `pg_migrate.sh dump` crashed on macOS bash 3.2; every Next.js Docker build failed (secret mount needed Dockerfile syntax 1.10); npm no-deps, pnpm build approvals and Yarn 2+ Docker builds failed (9c1b4a9); `pg_migrate.sh` did not mask query-string passwords (5674a79).
- Release round (2026-10-23):
  - `railway_inventory.sh` uses `service list` instead of the deprecated `service status --all`, its 4.x service-name fallback reads the target environment only (429dc69), and the summary no longer takes another environment's settings from `status --json` (03687e9).
  - `breach_check.sh` notes per variable whether old and new keys can be live together (50db57b).
  - `pg_migrate.sh`: every file under `--out` is mode 600 (997affc); `restore --role` grants and then revokes FDW usage so foreign servers restore, and `--out` is added to `.gitignore` (ffc7cf8); the gitignore helper no longer writes the repo root as an absolute path (76115b8).
  - Payload rotation advice split by major: `previousSecrets` / `rotateSecret` exist only in Payload 4 beta; credential-shaped test fixtures assembled at runtime so CI's secrets scan stays green (bfd8468).
  - README incident wording matches Railway's disclosure, CI runs every test suite, CHANGELOG added (8929857).
  - Yarn 2+ migrations in the tools image, `.yarnrc.yml` with `.yarn/` files, the `NPM_TOKEN` build secret, and Yarn 2+ prune (4eeced9); pnpm migrations in the tools image without egress (pnpm prefetch).
