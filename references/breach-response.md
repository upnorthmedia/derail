# Breach mode

Read this only when the user confirms their values were exposed: stored on Railway on or after
2026-10-21 (Railway's [environment-variable breach](https://blog.railway.com/p/security-disclosure-wednesday-october-21st)),
or leaked some other way. An ordinary migration never loads this file, and none of its steps run.

## Contents
1. What changes compared with an ordinary migration
2. Order of operations
3. `migration/BREACH.md`
4. Rotation without an outage
5. Session, signing and encryption secrets
6. Databases
7. What not to do

## 1. What changes

| Topic | Ordinary migration | Breach mode |
|---|---|---|
| Phase 0 | no extra step | fingerprint current values with `breach_check.sh --fingerprint` **before anything is rotated**, then write `migration/BREACH.md` |
| When keys rotate | after cutover (runbook Day 1-2) | **now**, on Railway, in priority order, before any migration work that copies values |
| Secret buckets in PLAN.md | re-source / keep identical through cutover / rotate after | re-source / rotate now / rotate at cutover. There is no "keep identical" bucket |
| Session and auth secrets | identical through cutover, rotated a week later with a re-login notice | rotated **at the cutover minute**; users log in again inside the downtime that already exists (section 5) |
| `put_secrets.sh` | no fingerprint file, no check | `migration/.secrets/railway.burned.sha256` sits next to the env file, so any exposed value is refused |
| Database password | rotated after cutover | rotated now, like every other exposed credential (section 6) |
| Railway TCP proxy (`DATABASE_PUBLIC_URL`) | deleted on Day 7 after cutover | deleted after the password rotation, before the first rehearsal dump; dumps use `railway connect postgres --tunnel-only`; re-created only for a dump or replication window, gone by cutover T+15 (data-migration.md section 2) |
| Between cutover and decommissioning | idle services, no extra step | Day 1: a canary credential planted in the old Railway environment, removed with the services; token kept active a few weeks longer (runbook section 6) |
| Before decommissioning | cost and traffic checks | `breach_check.sh --verify` passes, i.e. nothing on Railway still holds an exposed value |

## 2. Order of operations

1. **Fingerprint first.** With the Railway CLI logged in:
   `scripts/breach_check.sh --project <name> --fingerprint migration/.secrets/railway.burned.sha256 --out migration/BREACH-CHECK.md`.
   This must run before anyone rotates anything. A fingerprint of an already-rotated value protects
   nothing, so ask the user whether rotation has started; if it has, fingerprint anyway, and say that keys
   rotated before this point are covered only by the user's own record.
   No CLI access (the eval and offline cases): build BREACH.md from the inventory's names and say plainly
   that the exposed-value guard is not active.
2. **Write `migration/BREACH.md`** (section 3). Names only, like every other file.
3. **The user rotates on Railway**, in BREACH.md order, using section 4 to avoid taking production down.
   This is incident response and comes before the migration timeline, not inside it.
4. **Prove it**: `scripts/breach_check.sh --project <name> --verify migration/.secrets/railway.burned.sha256`.
   Exit 0 means no variable on Railway still holds an exposed value. Sealed variables are invisible to
   the CLI; the user confirms those by hand.
5. **Migrate with fresh values.** The AWS env file is filled from the rotated values. `put_secrets.sh`
   finds the fingerprint file next to the env file and refuses any match by key name. Use
   `--allow-carryover KEY` only for a value the user confirms is not a secret.
6. **Cutover rotates the session secrets** (section 5).

## 3. `migration/BREACH.md`

```
# Breach response: <project>
Exposure: values stored on Railway on/after 2026-10-21. Fingerprinted: <timestamp | "no, CLI unavailable">.
Guard: put_secrets.sh exposed-value check <active | NOT active, because ...>.

## Rotate now (in this order)
| # | Variable | Service(s) | Provider | Attacker could | Rotate | Dual-key? | Check for misuse |
| 1 | OPENAI_API_KEY | web, worker | OpenAI | run inference on your bill | API keys page: create, deploy, revoke | yes | usage and billing |
...

## Rotate at cutover
<session / signing / encryption secrets, with the method from section 5>

## Not visible to the scripts
<sealed variables (from the inventory's sealed_unavailable list), CI copies, laptop .env files>

## Status
- [ ] all "rotate now" rows done  - [ ] `breach_check.sh --verify` exit 0  - [ ] sealed values confirmed by hand
```

Priority order, the same as `breach_check.sh`: AI provider keys (Railway says the attackers were after
AI inference providers), cloud credentials, databases, payments, source/registry/deploy tokens,
session/signing secrets, webhook secrets, everything else. Fill the "Rotate", "Dual-key?" and "check
for misuse" columns from the provider table in section 4. For a provider that is not in it, write
"check the provider's docs" rather than guess a menu path or a grace period.

## 4. Rotation without an outage

- **Dual-key providers** let two credentials be valid at once (AWS IAM allows two access keys per user,
  for example). Create the new one, set it on Railway, deploy, confirm, then revoke the old one.
- **Hard-cut providers** allow one credential. Revoking it breaks production until the new value is
  deployed, so pair the two steps and do them together.
- Some providers keep the old key valid for a grace period when you roll it. After a breach, keep that
  window as short as your deploy allows.
- **Railway paused deployments during the incident.** Updating a variable does nothing for a running
  service until it redeploys. If deploys are paused, revoking first is an outage. Check
  status.railway.com before starting.
- Webhook signing secrets: until rotated, anyone can forge events your app accepts as genuine. Roll them
  at the sender with the other payments/provider keys.
- Railway's follow-up guidance for cloud keys:
  [AWS](https://blog.railway.com/p/security-disclosure-recommendation-check-for-anomalous-aws-access),
  [GCP](https://blog.railway.com/p/security-disclosure-recommendation-check-for-anomalous-gcp-access).

### Per provider

Copy the "Two live at once?" answer into BREACH.md's "Dual-key?" column as `yes`, `grace <window>` or
`no`. Every cell comes from the provider's own documentation, checked on 2026-10-22 (sources below the
table); providers change these rules, so re-check the linked page when a row matters. A provider that
is not listed gets "check the provider's docs", never a guess.

| Provider / credential | Two live at once? | Safe order | Check for misuse |
|---|---|---|---|
| OpenAI API key [1] | yes | Create a replacement, deploy it, confirm it works, revoke the old key. OpenAI says to rotate immediately if a key has leaked. | Usage page: does usage match your team's work? |
| Anthropic API key [2][3] | yes (keys per environment) | Anthropic's compromise advice is to revoke the key immediately, then create a new one. To avoid an outage, create the new key first and deploy it in the same sitting. (Our judgment, not Anthropic's: if you cannot deploy within minutes, revoke first anyway.) | Console **Logs** and **Usage** pages |
| AWS IAM access key [4] | yes, two per IAM user | Create the second key, deploy, check the old key's last-used time (`aws iam get-access-key-last-used`), deactivate it (`aws iam update-access-key`), confirm the app still works, then delete it. AWS suggests waiting days between steps; after a breach, deactivate as soon as the new key is confirmed. | Old key's last-used info; CloudTrail per Railway's AWS guidance above |
| GCP service account key [5][6] | yes, up to 10 keys per service account | Create a new key, deploy, disable the old key, delete it once nothing breaks. Google: deleting a key does not revoke short-lived credentials already issued from it. | Key Authentication Events metric (last use of a key); `serviceAccountKeyName` in Cloud Audit Logs entries; Railway's GCP guidance above |
| Stripe secret or restricted API key [7] | grace, up to 7 days | Rotate with an expiration just longer than your deploy (or **Now** if you can deploy at once), deploy, watch the old key's request logs reach zero, expire it. For more than 7 days, create a second key manually and expire the old one later. | Per-key **View request logs** (Workbench) |
| Stripe webhook signing secret [8] | grace, up to 24 hours | **Roll secret** with a delay just long enough to deploy; Stripe sends one signature per active secret until the old one expires. Deploy, then let it expire. | Compare what your handler processed against the endpoint's **Event deliveries** tab |
| GitHub personal access token [9][10] | yes (up to 50 fine-grained tokens) | Create a new token, deploy, delete the old one. | Your account's security log (last 90 days); the organization audit log for org resources |
| GitHub OAuth app client secret [11] | yes | GitHub's compromise procedure: generate a new secret, update the app to use it, delete the old secret. | check the provider's docs |
| GitHub App private key [12] | yes, up to 25 keys | Generate a new key, deploy, delete the old one (GitHub requires a new key before the last one can be deleted). | check the provider's docs |
| Postgres role password [13][14][15][16] | no, one password per role | `ALTER ROLE ... PASSWORD` and redeploy as one step, inside a short window. Authentication happens when a client connects, so sessions opened with the old password stay open: list them in `pg_stat_activity` and end unknown ones with `pg_terminate_backend`. Railway specifics: section 6. | `pg_stat_activity` (current sessions only). Past connections are logged only if `log_connections` was set; it is off by default. |
| Resend API key [17] | yes (multiple keys) | Create a new key, deploy, remove the old key. | Dashboard shows each key's last use and request count; the count links to that key's logs |
| Postmark server or account API token [18][19] | yes (server: generate new, then delete the old; account: up to three tokens) | **Generate New** on the server's API Tokens tab, deploy, delete the existing token. | check the provider's docs |
| Twilio Auth Token [20][21] | yes, via a secondary token | Create the secondary Auth Token, update and test every app with it, then promote it, which deletes the old primary. Services or Functions (Classic) that include the token directly instead of in a variable need 1 minute for the change to propagate. | Monitor events and Monitor logs for admin changes, message and call logs, usage records [22] |
| Twilio API key [20] | yes (separate keys per subsystem) | Create a new key, deploy, revoke the compromised key. | Same as the Auth Token row [22] |
| Sentry DSN (client key) [23][24] | yes (a project can have several client keys) | Sentry says DSNs are safe to keep public: they only submit events. Rotate or revoke under the project's **Client Keys (DSN)** settings if spam events are a concern. | check the provider's docs |
| Sentry auth token (`SENTRY_AUTH_TOKEN`) [25] | yes (Sentry recommends one token per use case) | Create a new organization or personal token, update CI, revoke the old one. | check the provider's docs |

Sources (checked 2026-10-22):

1. OpenAI, Best practices for API key safety: https://help.openai.com/en/articles/5112595-best-practices-for-api-key-safety
2. Anthropic, What should I do if I suspect my API key has been compromised: https://support.claude.com/en/articles/8384961-what-should-i-do-if-i-suspect-my-api-key-has-been-compromised
3. Anthropic, API key best practices: https://support.claude.com/en/articles/9767949-api-key-best-practices-keeping-your-keys-safe-and-secure
4. AWS, Update access keys: https://docs.aws.amazon.com/IAM/latest/UserGuide/id-credentials-access-keys-update.html
5. Google Cloud, Create and delete service account keys: https://docs.cloud.google.com/iam/docs/keys-create-delete
6. Google Cloud, Best practices for managing service account keys: https://docs.cloud.google.com/iam/docs/best-practices-for-managing-service-account-keys
7. Stripe, API keys (rotate, grace period, request logs): https://docs.stripe.com/keys
8. Stripe, Webhooks (roll endpoint signing secrets): https://docs.stripe.com/webhooks
9. GitHub, Managing your personal access tokens: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens
10. GitHub, Reviewing your security log: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/reviewing-your-security-log
11. GitHub, Best practices for creating an OAuth app: https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/best-practices-for-creating-an-oauth-app
12. GitHub, Managing private keys for GitHub Apps: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps
13. PostgreSQL, `pg_authid` (one `rolpassword` per role): https://www.postgresql.org/docs/current/catalog-pg-authid.html
14. PostgreSQL, Client authentication: https://www.postgresql.org/docs/current/client-authentication.html
15. PostgreSQL, Server signaling functions (`pg_terminate_backend`): https://www.postgresql.org/docs/current/functions-admin.html
16. PostgreSQL, Error reporting and logging (`log_connections`): https://www.postgresql.org/docs/current/runtime-config-logging.html
17. Resend, API keys: https://resend.com/docs/dashboard/api-keys/introduction
18. Postmark, How to cycle a server API token: https://postmarkapp.com/support/article/1293-how-to-cycle-a-server-api-token
19. Postmark, More than one account API token: https://postmarkapp.com/support/article/1212-can-you-have-more-than-one-account-api-token-at-a-time
20. Twilio, Auth Token API and API keys: https://www.twilio.com/docs/iam/api/authtoken and https://www.twilio.com/docs/iam/api-keys
21. Twilio, Fraud response guide, contain: https://www.twilio.com/docs/usage/fraud-response-guide/contain
22. Twilio, Fraud response guide, diagnose: https://www.twilio.com/docs/usage/fraud-response-guide/diagnose
23. Sentry, Data Source Name (DSN): https://docs.sentry.io/concepts/key-terms/dsn-explainer/
24. Sentry API, Create a new client key: https://docs.sentry.io/api/projects/create-a-new-client-key/
25. Sentry, Auth tokens: https://docs.sentry.io/account/auth-tokens/

## 5. Session, signing and encryption secrets

Anyone holding a leaked session secret can mint valid sessions. In breach mode these rotate at the cutover
minute, and the plan says users will log in again. Two traps:

- **The secret also encrypts stored data.** Swapping it outright makes that data unreadable.
- **Rotation helpers keep the old secret valid.** That is their point in a calm rotation, and exactly
  wrong after a leak.

Per library (verified against their docs on 2026-10-22; re-check the installed version):

- **Payload** (`PAYLOAD_SECRET`): signs JWT sessions, encrypts API keys and any field encrypted with
  `payload.encrypt`, and indexes API keys. Payload documents a `rotateSecret` utility plus a
  `previousSecrets` config. While the old secret is in `previousSecrets`, **tokens signed with it still
  verify**. So, inside the maintenance window with traffic stopped: set the new secret, add the old one to
  `previousSecrets`, run `rotateSecret` so everything is re-keyed, remove `previousSecrets`, then open
  traffic. Password logins are unaffected (hashes don't use the secret); sessions end.
- **Better Auth** (`BETTER_AUTH_SECRET` / `AUTH_SECRET`): used for encryption, signing and hashing.
  Versioned `secrets` (or `BETTER_AUTH_SECRETS`) put the new key first; older entries become
  decryption-only, and stored data re-encrypts lazily on write. Sessions live in the database: delete them
  at cutover so no session issued under the leaked secret survives. If cookie caching is on, confirm in
  the installed version's docs that a decryption-only key cannot validate a cookie before relying on it.
- **Anything else** (`JWT_SECRET`, `SESSION_SECRET`, `SECRET_KEY_BASE`, `NEXTAUTH_SECRET`): rotate,
  accept that sessions end, and if the library takes a list of previous secrets, do not put the leaked one
  in it. If `scan_codebase.py` or the code shows the secret encrypting stored data, plan a re-encryption
  step and say which rows it touches.

## 6. Databases

A leaked `DATABASE_URL` / `PGPASSWORD` is a login. With a public TCP proxy (`DATABASE_PUBLIC_URL`), anyone
on the internet could use it.

- Rotate the database password with the other "rotate now" rows, before the first rehearsal dump, then
  update the Postgres service's password variables so `${{Postgres.*}}` references follow. Check
  Railway's docs for the template version before doing this in production.
- Then delete the Railway TCP proxy (`railway tcp-proxy list --service <postgres>`, `railway tcp-proxy
  delete <id>`; CLI >= 5.15.0) so the rotated password is not reachable from the internet either.
  Dumps go over `railway connect postgres --tunnel-only` (CLI >= 5.27.0), which tunnels over SSH when no
  proxy exists. Re-create the proxy only for a window that needs it (logical replication, a client that
  cannot tunnel) and delete it again; the runbook deletes any remaining proxy at T+15
  (`references/data-migration.md` section 2).
- `pg_dump` copies functions, triggers, event triggers, rules, schemas, foreign servers and user mappings
  faithfully, including any an intruder added (roles, grants, publications and subscriptions are not
  copied by `dump`'s flags). Run `SRC_URL=... scripts/pg_migrate.sh audit` after rotating the password and
  before the first rehearsal dump. It is read-only and writes `migration/db/db-audit-<stamp>.md`: login
  roles and attributes, memberships, SECURITY DEFINER functions, triggers, event triggers, rules,
  extensions, schemas and owners, foreign servers / user mappings, publications / subscriptions and who is
  connected right now. Record anything unexplained in BREACH.md as an open question, remove it on the
  source (or keep it out of the dump), re-run the audit and diff the two reports (function definitions
  are identified by a hash), and complete its sign-off checklist before the final dump.
- A password change does not end sessions that are already open: authentication happens when a client
  connects. If the audit shows a connection you cannot account for, end it (`SELECT
  pg_terminate_backend(pid) ...` as the admin user) after rotating.
- A foreign-server user mapping stores another system's credential, and `pg_dump` writes it to the dump
  in plain text: treat that credential as exposed and keep dump directories out of git and shared drives.

## 7. What not to do

- Never read old values back to compare them; fingerprints exist so nobody has to.
- Never keep a leaked secret in a "previous secrets" list after traffic resumes.
- Never pull existing private-registry images if registry credentials were among the exposed values:
  whoever held the token could have pushed over a tag you still deploy. Build from source (the
  generated `deploy.yml` builds `runner`/`tools` from the checked-out commit and pushes only to the new
  ECR repository; the Terraform modules run only images from that repository). Base images in
  `assets/docker/Dockerfile.*` are pinned by digest, so a moved tag cannot change a build. Revoke the
  registry token at the registry itself, and do not copy an old private image into ECR to "save a
  rebuild".
- Nothing in this file changes the non-negotiables: no values in chat or files, nothing applied,
  nothing deleted on the source platform by the agent.
