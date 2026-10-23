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
session/signing secrets, webhook secrets, everything else. Fill the provider and "check for misuse"
columns only with what you know for that provider; write "check the provider's docs" rather than guess
a menu path.

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
- `pg_dump` copies roles' objects, functions and triggers faithfully, including any an intruder added.
  `pg_migrate.sh preflight` lists roles and event triggers; flag anything unexpected in BREACH.md as an
  open question rather than migrating it silently.

## 7. What not to do

- Never read old values back to compare them; fingerprints exist so nobody has to.
- Never keep a leaked secret in a "previous secrets" list after traffic resumes.
- Never pull existing private-registry images if registry credentials were among the exposed values;
  build from source (the generated workflows already do).
- Nothing in this file changes the non-negotiables: no values in chat or files, nothing applied,
  nothing deleted on the source platform by the agent.
