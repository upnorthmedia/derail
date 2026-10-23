# Cutover runbook template

Copy to `migration/RUNBOOK.md` and fill every `<...>`. Keep it boring: the goal is that someone other
than the author can execute and roll back. Timings assume a < 10 GB database; rehearsal numbers go in
section 2.

---

# <Project> cutover: <Railway/Vercel> -> AWS (<region>, account <id>)

Owner: <name>. Second pair of eyes: <name>. Window: <date> <start-end local time> (<UTC>).
Rollback decision deadline: flip + <60> min. Status channel: <link>.

## 1. Inventory delta (from migration/inventory)

| Item | Old | New |
|---|---|---|
| App URL | https://<domain> (Vercel/Railway) | https://<domain> (CloudFront/ALB `<dns>`) |
| Database | Railway Postgres <major> (<size> GB) `<service>` | RDS `<identifier>` PG <major>, `<class>` |
| Files | Vercel Blob store `<id>` / Railway bucket `<name>` | s3://<bucket> via https://<media-host> |
| Cron | <list> | EventBridge Scheduler `<names>` |
| Worker | <service> | ECS service `<name>-worker` |
| Secrets re-sourced | <list of Secret-type / sealed vars> | Secrets Manager `<project>-<env>/app` |
| Webhooks | <Stripe/Twilio/Typeform URLs> | <new URLs; dual-registered Y/N> |
| OAuth redirect URIs | <providers> | <added Y/N> |
| DNS | <registrar/zone, current TTL> | Route 53 zone `<id>` |

## 2. Rehearsal results (T-7 to T-2)

- [ ] *(Breach mode only)* Before the first rehearsal dump: Railway DB password rotated (BREACH.md row
      ticked) and the Railway TCP proxy deleted; dumps run over `railway connect postgres --tunnel-only`
      (references/data-migration.md section 2). Any window the proxy was re-created for: <dates/times>.
- [ ] Full dump -> restore into `app_rehearsal` on the real RDS: dump <min>, restore <min>, `pg_migrate.sh verify` OK.
- [ ] App stack pointed at the rehearsal DB and smoke-tested on the ALB/CloudFront hostname via `/etc/hosts`:
      login, one write, one upload, one webhook replay, cron task ran once (`aws ecs run-task` manual).
- [ ] Blob/bucket copy run in full; object counts match (`<n>` = `<n>`).
- [ ] Env parity diff: every key in the old inventory is in `secret_keys`, `plain_env`, build args, or
      explicitly dropped (list the dropped ones: `RAILWAY_*`, `VERCEL_*`, `BLOB_READ_WRITE_TOKEN`, ...).
- [ ] `terraform plan` on main is empty (no drift) and CI roles work (last PR plan + last apply green).
- [ ] Alarms fire: temporarily set an alarm threshold to 0, receive the email, revert. SNS subscription confirmed.
- [ ] Budget visible in AWS Budgets; cost allocation tags active (`Project` shows in Cost Explorer).
- [ ] RDS: deletion protection on, backups <n> days, first automated snapshot exists.

## 3. T-1 day

- [ ] Lower DNS TTL for `<apex>`, `www`, `<api>` to 60 s. If the zone is on Vercel DNS/Cloudflare, decide: move
      NS to Route 53 at T-7 (`create_hosted_zone = true`, `old_platform_records` = current apex/www targets,
      `extra_dns_records` = every MX/TXT/CNAME from the old zone, verify with `dig +norecurse @<ns>`; NS
      propagation up to 48 h; ACM validation records live in the new zone) or keep the old DNS provider
      and only change records at T-0. `traffic_target` stays `"old"` until the flip.
- [ ] Deploy ONLY the maintenance switch (`proxy.maintenance.ts`, cherry-picked) to the OLD platform with
      `MAINTENANCE_MODE=false`. The migration branch (adapter swaps, S3 storage, standalone) must not
      reach the old platform.
- [ ] Confirm AWS schedules are still disabled (`crons_enabled = false`) so nothing runs against the old
      database or sends duplicate messages before the flip.
- [ ] Dual-register webhooks and OAuth redirect URIs where the provider allows; note single-endpoint flips.
- [ ] Freeze schema migrations; confirm the last migration is applied on both sides.
- [ ] Pause Railway/Vercel crons that write (or confirm they are idempotent).
- [ ] Write new `app_rw` password into the app secret; `put_secrets.sh --diff` shows only expected keys.
- [ ] *(Breach mode only)* `breach_check.sh --verify migration/.secrets/railway.burned.sha256` exits 0 and
      every BREACH.md "rotate now" row is ticked. Session-secret rotation steps for T+15 are written out.
- [ ] Announce the window.

## 4. Cutover sequence

```
T+00  Announce start. Set MAINTENANCE_MODE=true on the old app (writes 503, reads OK). Pause old crons.
T+02  Confirm no writers on Railway:
        SELECT count(*) FROM pg_stat_activity WHERE state <> 'idle' AND backend_type = 'client backend';
      Optional hard stop: ALTER DATABASE railway SET default_transaction_read_only = on; terminate app backends.
T+03  Final dump:    SRC_URL=... scripts/pg_migrate.sh dump
T+08  Restore:       TGT_URL=... scripts/pg_migrate.sh restore --target-db app --role app_owner --clean
T+15  Verify:        scripts/pg_migrate.sh verify --target-db app   (counts + checksums + sequences OK)
      (Breach mode only) If the Railway TCP proxy was re-created for this dump or for replication
      (after DROP SUBSCRIPTION), delete it now: railway tcp-proxy delete <id>. `tcp-proxy list` shows none.
      (Breach mode only) Rotate session/auth secrets now, while no traffic flows: new value in the app
      secret, re-key encrypted data per references/breach-response.md section 5, delete sessions, remove
      any "previous secrets" entry holding the leaked value, force a new ECS deployment.
      Blob/bucket incremental copy (idempotent script). URL rewrite SQL for stored file URLs.
T+18  Smoke test AWS on its own hostname (MAINTENANCE_MODE is not set there): login, write, upload,
      webhook replay (Stripe "resend"), health endpoint, one cron RunTask.
T+20  Flip: set `traffic_target = "aws"` and `crons_enabled = true` in terraform.tfvars, `terraform apply`
      (creates the apex/www aliases to CloudFront/ALB and enables the schedules). On the old DNS provider,
      change the records instead. Flip single-endpoint webhooks (Twilio, Typeform).
      If the domain is attached to the Vercel project, remove it from Vercel AFTER DNS points away.
T+21  Watch for 20 min: ALB 5xx and target health, ECS events/restarts, RDS connections, CloudWatch
      logs, `dig +short <domain> @1.1.1.1 @8.8.8.8`, Stripe webhook attempts succeeding on the new URL.
T+40  Declare done. Leave Railway and Vercel RUNNING but idle (do not delete anything). Post status.
```

## 5. Rollback

Triggers: error rate > 2x baseline for 10 min after flip; verify mismatch; auth broken for all users;
uploads failing; any data-integrity doubt. Steps: `traffic_target = "old"`, `crons_enabled = false`,
apply (or change records at the old provider; 60 s TTL), `MAINTENANCE_MODE=false` on the old app,
`ALTER DATABASE railway SET default_transaction_read_only = off`, re-point single-endpoint webhooks. **Exposure**: rows written to RDS after the flip. Either accept and
announce, or export the delta (`pg_dump --data-only --table=<t>` where `updated_at > <flip time>`) and
apply it to Railway. After the decision deadline, rollback is no longer on the table; fix forward.

## 6. Post-cutover

- Day 1: first automated RDS snapshot exists; budget alert threshold test; no new objects in the old
  Blob store/bucket; raise DNS TTL back to 300-3600 s.
- Day 1-2: **rotate** what was exported or dual-registered: RDS app-user password, old webhook
  endpoints and secrets deleted, `BLOB_READ_WRITE_TOKEN`, any API key that lived in Vercel/Railway env.
  Schedule the `PAYLOAD_SECRET`/`AUTH_SECRET` rotation with a user re-login notice.
  *(Breach mode: these already rotated before or during cutover; skip this item.)*
- *(Breach mode only)* Day 1, after the rollback deadline: plant a canary credential in the old Railway
  environment, so that anyone who reads Railway's variables from now on and uses what they find raises an
  alert. The user picks the provider and creates it; for example (checked 2026-10-22) the free
  Canarytokens.org "AWS API Keys" token, which emails an alert when the key pair is used against the AWS
  API, 2-30 min late because alerts go through AWS logging (docs.canarytokens.org/guide/aws-keys-token.html),
  or the same token type from a paid Thinkst Canary console. Give it a memo naming the project and the
  Railway environment. Add the pair as two variables on one service in the old production environment,
  under names the app does not read (not in the `CODEBASE.md` env table; never `AWS_ACCESS_KEY_ID`,
  which an AWS SDK in the idle app would pick up and trip the alert itself), then Deploy the staged change
  (Railway applies variable edits only on deploy). Reading the variables (`railway variables`,
  `breach_check.sh --verify`) does not trip it; using the keys does. Record the variable names, service,
  provider and memo in BREACH.md, never the values. An alert means someone read Railway's variables after
  rotation: treat anything still stored on Railway as exposed, run `breach_check.sh --verify`, review the
  Railway workspace audit log (it records changes, not reads) and report it to Railway.
- Day 7: remove old OAuth redirect URIs; delete the Railway TCP proxy (Public Access); scale old
  services to 0 / sleep (keep volumes). *(Breach mode: the proxy is already gone; confirm
  `railway tcp-proxy list --service <postgres>` shows none.)*
- *(Breach mode)* Before scaling Railway down: run `breach_check.sh --verify` once more, then shred
  `migration/.secrets/railway.burned.sha256` with the other `.secrets/` files.
- Day 7-14: last `pg_dump` of Railway to S3 (encrypted, Glacier); delete Railway services/volumes,
  Vercel project and Blob store; shred local dumps and `migration/.secrets/`; drop `app_rehearsal`.
  *(Breach mode only)* The canary variables go with the Railway services. Keep the token itself active
  for a few weeks after that, since a copy read earlier can still be used later, then disable or delete
  it with the provider (check its docs for how) and close the BREACH.md row.
- Confirm in Cost Explorer that the project's tag shows the expected line items and that Railway/Vercel
  invoices stop.
