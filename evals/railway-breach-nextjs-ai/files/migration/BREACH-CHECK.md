# Railway exposure checklist

Generated 2026-10-22T09:14:03Z by `breach_check.sh`. Names only: no value appears in this file.
Context: Railway's [security disclosure of 2026-10-21](https://blog.railway.com/p/security-disclosure-wednesday-october-21st)
recommends rolling every environment variable. This file lists what that means for your account.

- Variables to rotate: **12** across 3 service instance(s)
- Short config-looking values left out: 8

Rotate in the order below. For keys a provider lets you run side by side (two active keys),
create the new one, deploy it, then revoke the old one. Note that Railway paused deployments
during the incident: if you can't deploy, revoking first takes the service down.

## 1. AI provider keys

Railway says the attackers were after AI inference providers. Revoke each key at the provider now, then check usage and billing for spend you did not make.

- [x] `ANTHROPIC_API_KEY` (quillnote/production/web)
- [x] `OPENAI_API_KEY` (quillnote/production/web)

## 2. Cloud credentials

Deactivate and replace. Railway published checks for anomalous [AWS](https://blog.railway.com/p/security-disclosure-recommendation-check-for-anomalous-aws-access) and [GCP](https://blog.railway.com/p/security-disclosure-recommendation-check-for-anomalous-gcp-access) access; review CloudTrail or Cloud Audit Logs for the old key.

- [ ] `AWS_ACCESS_KEY_ID` (quillnote/production/web)
- [ ] `AWS_SECRET_ACCESS_KEY` (quillnote/production/web)

## 3. Databases and caches

Change the password (`ALTER ROLE ... PASSWORD`) and update every variable that references it. If the database had a public TCP proxy it was reachable from the internet: review roles, connections and recent schema changes.

- [ ] `DATABASE_PUBLIC_URL` (quillnote/production/Postgres)
- [ ] `DATABASE_URL` (quillnote/production/Postgres)
- [ ] `PGPASSWORD` (quillnote/production/Postgres)
- [ ] `POSTGRES_PASSWORD` (quillnote/production/Postgres)

## 4. Payments

Roll the keys in the provider dashboard and review recent events, payouts and webhook endpoints for changes you did not make.

- [ ] `STRIPE_SECRET_KEY` (quillnote/production/web)
- [ ] `STRIPE_WEBHOOK_SECRET` (quillnote/production/web)

## 6. Session, signing and encryption secrets

Anyone holding these can forge sessions or signatures. Rotating logs users out. If the library also encrypts stored data with it (Payload, Better Auth), re-encrypt that data (with the library's rotation tooling where it has one; Payload 3 has none), then remove the old value: keeping it as an accepted 'previous' secret keeps forged tokens valid.

- [ ] `BETTER_AUTH_SECRET` (quillnote/production/web)

## 8. Other third-party keys and secrets (review)

Rotate at each provider. Some of these may be plain config; skip the ones that are not secrets.

- [ ] `GITHUB_CLIENT_SECRET` (quillnote/production/web)

## 9. References (rotate the source variable, not these)

These point at another variable (`${{Service.VAR}}`). Rotate the source variable; these follow automatically.

- [ ] `ANTHROPIC_API_KEY` (quillnote/production/worker)
- [ ] `DATABASE_URL` (quillnote/production/web, quillnote/production/worker)
- [ ] `OPENAI_API_KEY` (quillnote/production/worker)

## Not covered by this script

- **Sealed variables.** The CLI cannot read them, so they are missing above. Open each service in the
  Railway dashboard, find the sealed ones, and rotate them at their provider.
- **Railway account and project tokens** you created for CI. Revoke them in Railway's account settings and
  update the CI secret store that holds them.
- **Copies elsewhere.** The same key in GitHub Actions secrets, a laptop `.env`, or another host is the
  same key. Rotating means every copy.

Fingerprints of the current values were written to `migration/.secrets/railway.burned.sha256`. After rotating, run
`breach_check.sh --verify migration/.secrets/railway.burned.sha256` to prove nothing exposed is still in use.
