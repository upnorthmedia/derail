# valkey

One small ElastiCache for Valkey replication group: the replacement for a
Railway Redis service used as a job queue (BullMQ, Celery, Sidekiq), session
store or cache. Valkey speaks the Redis protocol; existing clients connect
unchanged apart from the `rediss://` scheme.

## What it creates

| Resource | Notes |
|---|---|
| `aws_elasticache_subnet_group` | Private subnets. |
| `aws_security_group` + one ingress rule per `allowed_security_group_ids` entry | 6379 only, from the listed SGs only. No egress rules (the engine never dials out). Rules are `count`-indexed so a first plan with unknown SG IDs works. |
| `aws_elasticache_parameter_group` `<name>-valkey<major>` | `maxmemory-policy` + `extra_parameters`. |
| `aws_elasticache_replication_group` `<name>-cache` | Engine `valkey`, **cluster mode disabled**, `num_cache_clusters` nodes, TLS required, encrypted at rest, daily snapshot, auto minor upgrades. |
| `aws_cloudwatch_metric_alarm` x3 (optional) | `EngineCPUUtilization` > 80% 15 min, `DatabaseMemoryUsagePercentage` > threshold, `Evictions` > 0. Only when `alarm_topic_arn` is set. |

## Why these choices

- **Cluster mode disabled, node-based.** Queue libraries use multi-key
  commands (`BRPOPLPUSH`, `MULTI` across keys, Lua scripts touching several
  keys). On a cluster-mode endpoint (which ElastiCache Serverless always is)
  those fail with `CROSSSLOT Keys in request don't hash to the same slot`.
  One primary with a single keyspace is what Railway gave you.
- **TLS required.** `transit_encryption_enabled` cannot be switched on later
  without replacing the group, so it is on from the start. Use `rediss://`.
- **No AUTH token.** `auth_token` lands in Terraform state in clear text and
  there is no write-only variant in the provider. The security group is the
  authentication boundary: only the ECS task security groups (and, during the
  migration, the migration host) can reach port 6379, and the instance has no
  public endpoint. If your policy requires AUTH anyway, set it out of band:
  `aws elasticache modify-replication-group --replication-group-id <id> --auth-token <token> --auth-token-update-strategy SET --apply-immediately`,
  then add `lifecycle { ignore_changes = [auth_token] }` to the resource and
  put the token in the app secret (`REDIS_URL` then carries a password and must
  move to `secret_keys`).
- **`noeviction` by default.** A broker that silently drops jobs when memory
  is full is worse than one that errors. Use `allkeys-lru` for a pure cache.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Base name; group id becomes `<name>-cache` (max 40 chars). |
| `vpc_id` | string | required | VPC for the security group. |
| `subnet_ids` | list(string) | required | Private subnets (>= 2). |
| `allowed_security_group_ids` | list(string) | required | SGs allowed on 6379. Append at the end. |
| `engine_version` | string | `"8.0"` | Valkey version; family derived (`valkey8`). |
| `node_type` | string | `"cache.t4g.micro"` | ~$11.68/mo; `cache.t4g.small` ~$23. |
| `num_cache_clusters` | number | `1` | Nodes (1 primary + replicas). 2+ = failover + Multi-AZ, doubles cost. |
| `maxmemory_policy` | string | `"noeviction"` | `noeviction` for queues, `allkeys-lru` for caches. |
| `extra_parameters` | map(string) | `{}` | e.g. `{ "notify-keyspace-events" = "Ex" }`. |
| `snapshot_retention_limit` | number | `1` | Daily snapshots kept (0 = none). |
| `snapshot_window` | string | `"02:00-03:00"` | UTC. |
| `maintenance_window` | string | `"sun:03:30-sun:04:30"` | UTC; single-node groups blip during it. |
| `apply_immediately` | bool | `false` | Apply changes now instead of in the window. |
| `kms_key_arn` | string | `null` | CMK for at-rest encryption. |
| `alarm_topic_arn` | string | `null` | SNS topic for the three alarms. |
| `memory_alarm_threshold_percent` | number | `80` | Memory alarm threshold. |

## Outputs

| Name | Description |
|---|---|
| `primary_endpoint_address` | Primary hostname. |
| `reader_endpoint_address` | Reader hostname (same node when single). |
| `port` | 6379. |
| `redis_url` | `rediss://<host>:6379/0`, no credentials, safe as plain env. |
| `security_group_id` | Cache SG. |
| `replication_group_id` / `replication_group_arn` | For CLI / IAM. |

## Cost (us-east-1, Oct 2026)

| Setting | Monthly |
|---|---|
| Defaults (1 x cache.t4g.micro) | ~$12 |
| `node_type = "cache.t4g.small"` | ~$23 |
| `num_cache_clusters = 2` (Multi-AZ failover) | x2 + a little cross-AZ transfer |

Backup storage up to the node's memory size is free; alarms are free within
the first 10 per account, then $0.10 each.

## Gotchas

1. **`rediss://`, not `redis://`.** With `transit_encryption_mode = "required"`
   a plain connection is refused with a confusing `ECONNRESET`. ioredis:
   `new Redis(url, { tls: {} })` is implied by the scheme in recent versions;
   BullMQ needs `maxRetriesPerRequest: null` as always. Celery:
   `broker_use_ssl = {"ssl_cert_reqs": "required"}` or `?ssl_cert_reqs=required`
   on the URL.
2. **Memory on `cache.t4g.micro` is ~0.5 GiB** (`maxmemory` is set by
   ElastiCache, lower than the instance RAM). Big BullMQ job payloads or
   session blobs fill it quickly; watch the memory alarm the first week.
3. **BullMQ delayed/repeatable jobs** need `notify-keyspace-events = "Ex"`
   only on very old versions; current BullMQ polls. Add it through
   `extra_parameters` only if the docs for your version ask for it.
4. **Engine upgrades are in place** (`auto_minor_version_upgrade`); a major
   bump (`engine_version`) is also in place but reboots a single-node group.
5. **The security group list is `count`-indexed.** Removing an entry from the
   middle re-creates the rules after it (a second of churn). Append new SGs.
6. **Data migration.** There is no managed "import from another Redis". For
   queues: drain them on the old platform before cutover and start empty.
   For sessions/caches: let them repopulate. If you must copy data, run
   `redis-cli --rdb` on the source and `restore` keys from the migration host
   (`modules/migration_host`), which is allowed on this SG by the root.
