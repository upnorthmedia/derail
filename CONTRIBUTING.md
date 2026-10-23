# Contributing

Thanks for helping keep this skill accurate. Railway, Vercel and AWS change monthly; the most valuable
contributions are corrections with a source link.

## Ground rules

- **No secret values, anywhere.** Scripts print names and counts; documents use placeholders; fixtures
  under `evals/` use fictional projects, `.example` domains and empty `.env` values. A PR that echoes a
  value, however fake, will be asked to change.
- **Primary sources.** Prices, CLI flags, resource arguments and version numbers must come from
  vendor documentation or registries. Put the URL in the PR description and, for prices, the date.
- **Validated Terraform.** Every root under `assets/terraform/` must pass `terraform fmt -check`,
  `terraform init -backend=false && terraform validate`, and `tflint` (config in `.tflint.hcl`). The CI
  workflow runs these on every PR.
- **Plain resources over modules** for anything an operator will debug; explain *why* in comments,
  including what a choice costs per month.
- **Portable Terraform**: `required_version = ">= 1.11, < 2.0"`, no HCP-only features, literal
  `prevent_destroy`, so the code runs on OpenTofu too.

## Local checks

```bash
# Terraform (needs terraform >= 1.11 or tofu, and tflint)
cd assets/terraform
for r in bootstrap network platform live/example-app/prod; do
  (cd "$r" && terraform init -backend=false && terraform validate)
done
tflint --recursive

# Scripts
shellcheck -S warning scripts/*.sh
shellcheck -x -S warning scripts/tests/*.sh scripts/lib/*.sh
for t in scripts/tests/*.sh; do bash "$t"; done   # BASH_UNDER_TEST=/bin/bash for macOS bash 3.2
# test_pg_audit.sh needs docker and psql/pg_dump/pg_restore >= 17 (it starts postgres:17); it SKIPs without them
python3 -m py_compile scripts/*.py
python3 scripts/scan_codebase.py evals/payload-cms-vercel-railway/files/lumen --stdout --json-only | head
python3 scripts/estimate_cost.py --tier shared

# Skill structure (from the skill-creator skill, if you have it)
python3 -m scripts.quick_validate /path/to/derail
```

## Adding an eval case

Create `evals/<case-name>/` with `prompt.md` (settings block + the user's prompt), `case.yaml`,
`graders/01-expected-output.md`, `place-files.sh`, and `files/` holding a small fixture repo and a
`migration/inventory/.../SUMMARY.md` written the way `scripts/*_inventory.sh` would write it (names
only). Keep fixtures fictional. Run with `claude plugin eval . --allow-tools Write,Edit,Bash --scaffold`.

## Adding a framework

1. A Dockerfile in `assets/docker/` (non-root, tini, arm64, RDS CA bundle, `tools` stage if the
   runtime image cannot run migrations).
2. A section in `references/app-changes.md`: port binding, health route, proxy headers, DB TLS,
   migrations command, framework-specific gotchas.
3. Scanner detection in `scripts/scan_codebase.py` (framework, port, migration tool).
4. Ideally an eval case.

## Reporting a problem

Open an issue with the platform (Railway/Vercel/AWS), the command or document, what you expected,
what happened, and the documentation link that shows the current behaviour. Please redact anything
identifying from inventories or logs before pasting.
