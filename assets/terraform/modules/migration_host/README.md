# migration_host

A disposable EC2 instance inside the VPC for the data-migration window. RDS and
ElastiCache have no public endpoints; this host is where `pg_dump | pg_restore`
runs, close to the target, and the thing your laptop port-forwards through for
a GUI client. Reached **only** through AWS Systems Manager Session Manager: no
SSH key, no inbound security-group rule, no public port.

Create it for the rehearsal and the cutover (`enable_migration_host = true` in
the root), destroy it afterwards (`false`, apply). It costs ~$5/month while it
exists (t4g.nano + 20 GiB gp3) and nothing when it does not.

## What it creates

| Resource | Notes |
|---|---|
| `aws_security_group` `<name>-migration-host` | No ingress. Egress all (SSM, dnf, the old platform's DB proxy, RDS, Valkey). |
| `aws_iam_role` + instance profile | `AmazonSSMManagedInstanceCore`; optional S3 read/write under `staging_bucket_arn`/`staging_prefix`; optional `secretsmanager:GetSecretValue` on `readable_secret_arns`. |
| `aws_instance` | Latest Amazon Linux 2023 (`architecture`), `instance_type`, IMDSv2 only, encrypted gp3 root, no key pair. `user_data` installs `postgresql<pg_major>`, jq/zstd/pv, the RDS CA bundle and (optionally) Docker. |

The root wires the host's security group into `rds_postgres` and `valkey`
(`allowed_security_group_ids`), so once the instance is up, `psql` to the RDS
endpoint just works.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Base name. |
| `vpc_id` | string | required | VPC. |
| `subnet_id` | string | required | Private subnet (needs NAT) or public subnet with `assign_public_ip`. |
| `assign_public_ip` | bool | `false` | Outbound reach without NAT; nothing listens on it. |
| `instance_type` | string | `"t4g.nano"` | ~$3/mo. `t4g.small` for `pg_restore -j 4` on multi-GB databases. |
| `architecture` | string | `"arm64"` | Must match the instance family (`t4g` = arm64). |
| `pg_major` | number | `18` | Client major = target RDS major. |
| `install_docker` | bool | `true` | Docker as the client fallback (see gotcha 1). |
| `root_volume_gib` | number | `20` | gp3 root. |
| `staging_bucket_arn` | string | `null` | Bucket the host may read/write. |
| `staging_prefix` | string | `""` | Limit S3 access to this prefix. |
| `readable_secret_arns` | list(string) | `[]` | Secrets the host may read (RDS master, app secret). |
| `port_forward_hosts` | map(object) | `{}` | `{ postgres = { host, port, local_port } }`, rendered into `port_forward_commands`. |
| `kms_key_arn` | string | `null` | CMK for the root volume. |

## Outputs

| Name | Description |
|---|---|
| `instance_id` | `--target` for SSM. |
| `security_group_id` | To allow on RDS/Valkey SGs. |
| `role_arn` | Instance role. |
| `session_command` | `aws ssm start-session --target i-...` |
| `port_forward_commands` | Map of ready-to-paste port-forward commands. |
| `pg_major` | Echo of the input. |

## How to use it

```sh
# 1. in the root: enable_migration_host = true, apply (2-3 minutes incl. user_data)
terraform output -raw migration_host_session_command | bash      # interactive shell
cat /opt/migration/READY                                          # user_data finished?
psql --version                                                    # expect the target major

# 2. dump from the old platform and restore into RDS, on the host
export SRC_URL='postgresql://...old platform...?sslmode=require'
export TGT_URL="postgresql://postgres:<pw>@<rds endpoint>:5432/app?sslmode=verify-full&sslrootcert=/usr/local/share/rds-global-bundle.pem"
pg_dump -Fc --no-owner --no-acl "$SRC_URL" -f /opt/migration/app.dump
pg_restore -d "$TGT_URL" --no-owner --no-acl -j 2 /opt/migration/app.dump

# 3. from your laptop, a GUI client against RDS through the host
terraform output -json migration_host_port_forward_commands        # paste the "postgres" one
#    then connect to localhost:15432

# 4. after day-7 checks: enable_migration_host = false, apply
```

The master password comes from `aws secretsmanager get-secret-value --secret-id
<db_master_secret_arn>` (the role may read it when the root passes the ARN in
`readable_secret_arns`); assemble `TGT_URL` in the shell, never in a file that
leaves the host.

## Gotchas

1. **`postgresql<major>` may not be packaged yet.** Amazon Linux 2023 ships
   `postgresql15`/`16`/`17` in its own repo and newer majors arrive months
   later; the PGDG RHEL 9 repo the script falls back to is not officially
   supported on AL2023 and occasionally has unmet dependencies. If
   `psql --version` is missing or wrong, use Docker (installed by default):
   ```sh
   alias pg_dump='docker run --rm -i --network host -v /opt/migration:/opt/migration postgres:18 pg_dump'
   alias pg_restore='docker run --rm -i --network host -v /opt/migration:/opt/migration postgres:18 pg_restore'
   alias psql='docker run --rm -it --network host postgres:18 psql'
   ```
   `--network host` lets the container resolve the RDS endpoint through the VPC.
2. **A dump client older than the source server fails.** `pg_dump` must be the
   same or a newer major than the source database; `pg_restore` must match the
   target. Setting `pg_major` to the target major satisfies both when the
   target is >= the source (the normal case).
3. **Private subnet = NAT required.** Without the network root's NAT gateway
   the instance never registers with SSM (`TargetNotConnected`). Either enable
   NAT or launch in a public subnet with `assign_public_ip = true`.
4. **The Session Manager plugin** must be installed on your laptop; the AWS CLI
   alone cannot open sessions. `ssm-user` on the host has sudo.
5. **`t4g.nano` has 0.5 GiB RAM.** `pg_restore -j 4` of a large dump can be
   OOM-killed; use `-j 1`/`-j 2` or `t4g.small`.
6. **The role can read secrets.** That is deliberate for the migration window
   and another reason to destroy the host afterwards.
7. **`user_data_replace_on_change`** means editing the bootstrap script
   replaces the instance; anything in `/opt/migration` is lost. Keep dumps in
   the staging bucket if you need them to survive.
