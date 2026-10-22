#!/usr/bin/env python3
"""estimate_cost.py - itemized monthly AWS estimate for the ECS Fargate + RDS + S3 target.

Usage:
  python3 estimate_cost.py --tier budget|standard|production [overrides] [--railway-monthly 48] [--json]

Overrides (any omitted value comes from the tier):
  --tasks N                 always-on Fargate tasks (web)
  --cpu 256|512|1024|2048   vCPU units per task (256 = 0.25 vCPU)
  --memory MB               memory per task (512..16384; must be a valid Fargate combo)
  --db-class db.t4g.micro|db.t4g.small|db.t4g.medium
  --db-storage-gb N         gp3 storage (default 20)
  --multi-az / --single-az
  --nat / --no-nat          NAT gateway (tasks in private subnets, no per-task public IP)
  --cloudfront free|pro|payg|none
  --waf                     AWS WAF pay-as-you-go on the distribution (only matters with payg/none)
  --cache none|valkey-serverless|t4g.micro
  --alb dedicated|shared:N  dedicated ALB or 1/N share of an ALB shared across projects
  --alb-internal            ALB has no public IPv4 (behind CloudFront VPC origin)
  --secrets N               Secrets Manager secrets (0.40 each)
  --logs-gb N               CloudWatch Logs ingested per month
  --container-insights      Container Insights enhanced observability (~10/mo)
  --worker-tasks N          extra always-on worker tasks (same size; on-demand by default)
  --worker-spot             price worker tasks as Fargate Spot (~70%% off on-demand, UNVERIFIED current rate;
                            Spot tasks can be interrupted with 2 min notice, fine for idempotent queue workers)
  --kms                     per-project KMS customer-managed key ($1/mo + requests). Never implied by a tier:
                            the default is AWS-managed keys (free) for RDS, Secrets Manager and S3
  --s3-gb N                 S3 Standard storage for media/uploads ($0.023/GB-mo; requests and egress extra)
  --efs-gb N                EFS Standard storage ($0.30/GB-mo) when a Railway volume becomes an EFS mount
  --migration-host          temporary t4g.nano EC2 jump/migration host in the VPC (~$3.07 + $3.65 public IPv4
                            per month while it exists; delete it after cutover)
  --region us-east-1        annotation only; prices below are us-east-1 list prices (eu-*/ap-* run 5-20%% higher)
  --railway-monthly USD     current Railway (or Vercel+Railway) bill, to print the delta
  --json                    machine-readable output

Prices verified 2026-10-22 (us-east-1, aws.amazon.com pricing pages; RDS instance prices from
secondary sources dated July 2026). 730 h/month. DATA TRANSFER IS EXCLUDED (internet egress
$0.09/GB after 100 GB, NAT processing $0.045/GB, cross-AZ $0.01/GB). Stdlib only.
"""
import argparse
import json
import sys

HOURS = 730.0
RATES = {
    "fargate_arm_vcpu_hour": 0.03238,
    "fargate_arm_gb_hour": 0.00356,
    "fargate_spot_discount": 0.70,           # "up to 70%"; UNVERIFIED current Spot rate
    "alb_hour": 16.43,                       # 0.0225/h * 730
    "alb_lcu_month": 2.00,                   # ~0.3 LCU-h avg at low traffic
    "public_ipv4_month": 3.65,               # 0.005/h * 730, per address
    "alb_public_ipv4_count": 2,
    "nat_hour_month": 32.85,                 # 0.045/h * 730 (1 AZ)
    "rds": {"db.t4g.micro": 11.68, "db.t4g.small": 23.36, "db.t4g.medium": 47.45},
    "gp3_gb_month": 0.115,
    "cloudfront": {"free": 0.0, "pro": 15.0, "payg": 0.0, "none": 0.0},
    "waf_payg_month": 8.00,                  # web ACL 5 + ~3 managed rule groups 3; request fees excluded
    "cache": {"none": 0.0, "valkey-serverless": 6.13, "t4g.micro": 9.34},
    "kms_cmk_month": 1.00,
    "s3_standard_gb_month": 0.023,          # first 50 TB tier; PUT/GET requests and egress excluded
    "efs_standard_gb_month": 0.30,          # EFS Standard (One Zone 0.16; IA 0.025 + access fees)
    "ec2_t4g_nano_month": 3.07,             # 0.0042/h * 730
    "secret_month": 0.40,
    "logs_gb_month": 0.50,
    "container_insights_month": 10.00,
    "route53_zone_month": 0.50,
    "ecr_month": 0.10,
    "alarms_month": 0.20,                    # ~12 alarms, 10 free
    "backup_vault_month": 2.00,              # AWS Backup incremental ~20 GB (production only)
    "scheduler_month": 0.20,                 # EventBridge Scheduler + short Fargate job
}

TIERS = {
    # kms is never set by a tier: a customer-managed key is an explicit --kms choice.
    "budget": dict(tasks=1, cpu=256, memory=1024, db_class="db.t4g.micro", db_storage_gb=20, multi_az=False, nat=False,
                   cloudfront="free", waf=False, cache="none", alb="dedicated", alb_internal=False, secrets=2, logs_gb=2,
                   container_insights=False, worker_tasks=0, worker_spot=False, kms=False, backup=False, scheduler=False,
                   s3_gb=0, efs_gb=0, migration_host=False, db="dedicated", spot_web=False),
    "standard": dict(tasks=1, cpu=512, memory=1024, db_class="db.t4g.small", db_storage_gb=20, multi_az=False, nat=False,
                     cloudfront="pro", waf=False, cache="none", alb="dedicated", alb_internal=False, secrets=3, logs_gb=5,
                     container_insights=False, worker_tasks=0, worker_spot=False, kms=False, backup=False, scheduler=True,
                     s3_gb=0, efs_gb=0, migration_host=False, db="dedicated", spot_web=False),
    # Agency mode: several small projects share one ALB and one RDS instance (platform/ root); this is the
    # per-project marginal cost with 4 tenants. Spot web task is the aggressive option; see --spot-web.
    "shared": dict(tasks=1, cpu=256, memory=512, db_class="db.t4g.small", db_storage_gb=20, multi_az=False, nat=False,
                   cloudfront="free", waf=False, cache="none", alb="shared:4", alb_internal=False, secrets=1, logs_gb=1,
                   container_insights=False, worker_tasks=0, worker_spot=False, kms=False, backup=False, scheduler=False,
                   s3_gb=0, efs_gb=0, migration_host=False, db="shared:4", spot_web=False),
    "production": dict(tasks=2, cpu=512, memory=1024, db_class="db.t4g.small", db_storage_gb=20, multi_az=True, nat=True,
                       cloudfront="payg", waf=True, cache="valkey-serverless", alb="dedicated", alb_internal=True, secrets=4, logs_gb=8,
                       container_insights=True, worker_tasks=1, worker_spot=False, kms=False, backup=True, scheduler=True,
                       s3_gb=0, efs_gb=0, migration_host=False, db="dedicated", spot_web=False),
}
VALID_FARGATE = {256: (512, 1024, 2048), 512: tuple(range(1024, 4097, 1024)), 1024: tuple(range(2048, 8193, 1024)),
                 2048: tuple(range(4096, 16385, 1024)), 4096: tuple(range(8192, 30721, 1024))}


def parse_args(argv):
    ap = argparse.ArgumentParser(description="Monthly AWS cost estimate (ECS Fargate + RDS + S3 target). Prices verified 2026-10-22 us-east-1; data transfer excluded.")
    ap.add_argument("--tier", choices=sorted(TIERS), default="standard")
    ap.add_argument("--tasks", type=int)
    ap.add_argument("--cpu", type=int, choices=sorted(VALID_FARGATE))
    ap.add_argument("--memory", type=int, help="MB per task")
    ap.add_argument("--db-class", choices=sorted(RATES["rds"]))
    ap.add_argument("--db-storage-gb", type=int)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--multi-az", dest="multi_az", action="store_true", default=None)
    g.add_argument("--single-az", dest="multi_az", action="store_false")
    g2 = ap.add_mutually_exclusive_group()
    g2.add_argument("--nat", dest="nat", action="store_true", default=None)
    g2.add_argument("--no-nat", dest="nat", action="store_false")
    ap.add_argument("--cloudfront", choices=sorted(RATES["cloudfront"]))
    ap.add_argument("--waf", action="store_true", default=None)
    ap.add_argument("--cache", choices=sorted(RATES["cache"]))
    ap.add_argument("--alb", help="dedicated | shared:N")
    ap.add_argument("--alb-internal", action="store_true", default=None)
    ap.add_argument("--db", help="dedicated | shared:N  (1/N share of one RDS instance + storage shared by N projects; platform/ root)")
    ap.add_argument("--cron", action="store_true", default=None, help="add the EventBridge Scheduler + short Fargate job line (any tier)")
    ap.add_argument("--spot-web", action="store_true", default=None, help="price the web task(s) as Fargate Spot (~70%% off, unverified; interruptions possible)")
    ap.add_argument("--secrets", type=int)
    ap.add_argument("--logs-gb", type=float)
    ap.add_argument("--container-insights", action="store_true", default=None)
    ap.add_argument("--worker-tasks", type=int)
    ap.add_argument("--worker-spot", action="store_true", default=None, help="price worker tasks as Fargate Spot (~70%% off, unverified)")
    ap.add_argument("--kms", action="store_true", default=None, help="add a per-project KMS customer-managed key")
    ap.add_argument("--s3-gb", type=float, help="S3 Standard GB stored (media/uploads)")
    ap.add_argument("--efs-gb", type=float, help="EFS Standard GB stored (volume replacement)")
    ap.add_argument("--migration-host", action="store_true", default=None, help="temporary t4g.nano EC2 host + public IPv4")
    ap.add_argument("--region", default="us-east-1")
    ap.add_argument("--railway-monthly", type=float, help="current monthly bill on Railway/Vercel in USD")
    ap.add_argument("--json", action="store_true")
    return ap.parse_args(argv)


def estimate(cfg):
    items = []
    notes = []

    def add(name, amount, detail=""):
        items.append({"item": name, "monthly_usd": round(amount, 2), "detail": detail})

    vcpu = cfg["cpu"] / 1024.0
    gb = cfg["memory"] / 1024.0
    if cfg["memory"] not in VALID_FARGATE.get(cfg["cpu"], ()):
        notes.append("WARNING: %d vCPU-units / %d MB is not a valid Fargate combination" % (cfg["cpu"], cfg["memory"]))
    task_month = (vcpu * RATES["fargate_arm_vcpu_hour"] + gb * RATES["fargate_arm_gb_hour"]) * HOURS
    if cfg.get("spot_web"):
        spot_web = task_month * (1 - RATES["fargate_spot_discount"])
        add("Fargate web tasks (Spot, ARM64)", spot_web * cfg["tasks"],
            "%d x %.2g vCPU / %g GB = ~$%.2f each on Spot (~70%% off, UNVERIFIED rate; on-demand $%.2f; a 2-min interruption notice means brief 5xx unless 2+ tasks)" % (cfg["tasks"], vcpu, gb, spot_web, task_month))
    else:
        add("Fargate web tasks (ARM64)", task_month * cfg["tasks"],
            "%d x %.2g vCPU / %g GB = $%.2f each (%.5f/vCPU-h, %.5f/GB-h)" % (cfg["tasks"], vcpu, gb, task_month, RATES["fargate_arm_vcpu_hour"], RATES["fargate_arm_gb_hour"]))
    if cfg["worker_tasks"]:
        if cfg.get("worker_spot"):
            spot = task_month * (1 - RATES["fargate_spot_discount"])
            add("Fargate worker tasks (Spot, ARM64)", spot * cfg["worker_tasks"], "%d x $%.2f (~70%% Spot discount, UNVERIFIED current rate; on-demand would be $%.2f each; 2-min interruption notice)" % (cfg["worker_tasks"], spot, task_month))
        else:
            add("Fargate worker tasks (on-demand, ARM64)", task_month * cfg["worker_tasks"], "%d x $%.2f (same size as web; --worker-spot for ~70%% off, unverified)" % (cfg["worker_tasks"], task_month))

    if cfg["nat"]:
        add("NAT gateway (1 AZ)", RATES["nat_hour_month"] + RATES["public_ipv4_month"], "hourly $%.2f + 1 public IPv4 $%.2f; data processing $0.045/GB excluded" % (RATES["nat_hour_month"], RATES["public_ipv4_month"]))
    else:
        n_ips = cfg["tasks"] + cfg["worker_tasks"]
        add("Public IPv4 for task ENIs", RATES["public_ipv4_month"] * n_ips, "%d task(s) in public subnets x $%.2f (no NAT)" % (n_ips, RATES["public_ipv4_month"]))

    alb_share = 1.0
    alb_label = "dedicated"
    if str(cfg["alb"]).startswith("shared:"):
        try:
            n = int(str(cfg["alb"]).split(":", 1)[1])
            alb_share = 1.0 / max(n, 1)
            alb_label = "1/%d share" % n
        except ValueError:
            notes.append("WARNING: --alb shared:N expects an integer; treating as dedicated")
    alb_ipv4 = 0 if cfg["alb_internal"] else RATES["public_ipv4_month"] * RATES["alb_public_ipv4_count"]
    alb_total = (RATES["alb_hour"] + RATES["alb_lcu_month"] + alb_ipv4) * alb_share
    add("Application Load Balancer (%s%s)" % (alb_label, ", internal" if cfg["alb_internal"] else ""), alb_total,
        "hourly $%.2f + ~LCU $%.2f + %s" % (RATES["alb_hour"], RATES["alb_lcu_month"], "no public IPv4" if cfg["alb_internal"] else "2 public IPv4 $%.2f" % alb_ipv4))

    cf = RATES["cloudfront"][cfg["cloudfront"]]
    cf_detail = {"free": "Free plan: TLS, 5 WAF rules, Route 53 zone, 100 GB (if eligible)", "pro": "Pro plan: WAF 25 rules incl. managed groups, zone, logs, 10 M req",
                 "payg": "pay-as-you-go: ~$0 under 1 TB / 10 M requests free tier", "none": "no CloudFront (ALB serves TLS directly; needs ACM + Route 53)"}[cfg["cloudfront"]]
    add("CloudFront (%s)" % cfg["cloudfront"], cf, cf_detail)
    if cfg["waf"] and cfg["cloudfront"] in ("payg", "none"):
        add("AWS WAF (pay-as-you-go)", RATES["waf_payg_month"], "web ACL $5 + ~3 managed rule groups $3; $0.60/M requests excluded")

    db = RATES["rds"][cfg["db_class"]]
    mult = 2 if cfg["multi_az"] else 1
    db_share = 1.0
    db_label = ""
    if str(cfg.get("db", "dedicated")).startswith("shared:"):
        try:
            n = int(str(cfg["db"]).split(":", 1)[1])
            db_share = 1.0 / max(n, 1)
            db_label = ", 1/%d share of one shared instance" % n
        except ValueError:
            notes.append("WARNING: --db shared:N expects an integer; treating as dedicated")
    add("RDS PostgreSQL %s%s%s" % (cfg["db_class"], " Multi-AZ" if cfg["multi_az"] else " single-AZ", db_label), db * mult * db_share,
        "$%.2f%s; includes automated backups up to 100%% of storage%s" % (db, " x2 Multi-AZ" if cfg["multi_az"] else "", "; one database + roles per project, max_connections shared (~190 on t4g.small)" if db_share < 1 else ""))
    add("RDS gp3 storage%s" % (" (shared)" if db_share < 1 else ""), RATES["gp3_gb_month"] * cfg["db_storage_gb"] * mult * db_share, "%d GB x $%.3f%s%s" % (cfg["db_storage_gb"], RATES["gp3_gb_month"], " x2 Multi-AZ" if cfg["multi_az"] else "", " / %d" % n if db_share < 1 else ""))
    if cfg["backup"]:
        add("AWS Backup vault (daily 35 d + weekly 90 d)", RATES["backup_vault_month"], "~20 GB incremental")

    if cfg["cache"] != "none":
        add("ElastiCache %s" % cfg["cache"], RATES["cache"][cfg["cache"]], "Serverless Valkey idle floor (100 MB min) / cache.t4g.micro Valkey node" if cfg["cache"] != "none" else "")

    if cfg.get("s3_gb"):
        add("S3 Standard (media/uploads)", RATES["s3_standard_gb_month"] * cfg["s3_gb"], "%g GB x $%.3f; PUT $0.005/1k, GET $0.0004/1k and egress excluded (serve through CloudFront: S3->CloudFront transfer is free, viewer egress bills under CloudFront)" % (cfg["s3_gb"], RATES["s3_standard_gb_month"]))
    if cfg.get("efs_gb"):
        add("EFS Standard (volume replacement)", RATES["efs_standard_gb_month"] * cfg["efs_gb"], "%g GB x $%.2f; 13x the S3 rate, elastic throughput billed per GB transferred; prefer S3 unless the app needs POSIX" % (cfg["efs_gb"], RATES["efs_standard_gb_month"]))
    if cfg.get("migration_host"):
        add("Migration host (t4g.nano + public IPv4)", RATES["ec2_t4g_nano_month"] + RATES["public_ipv4_month"], "$%.2f instance + $%.2f IPv4 per month WHILE IT EXISTS; terminate after cutover (or use SSM Session Manager port forwarding and skip the public IP)" % (RATES["ec2_t4g_nano_month"], RATES["public_ipv4_month"]))
    if cfg["kms"]:
        add("KMS customer-managed key", RATES["kms_cmk_month"], "per-project CMK (--kms; plus $0.03/10k requests). AWS-managed keys cost nothing")
    add("Secrets Manager", RATES["secret_month"] * cfg["secrets"], "%d secret(s) x $%.2f (app JSON secret + RDS managed master password + ...)" % (cfg["secrets"], RATES["secret_month"]))
    add("CloudWatch Logs", RATES["logs_gb_month"] * cfg["logs_gb"], "%g GB ingested x $%.2f (Standard class; 5 GB free on Free Tier accounts)" % (cfg["logs_gb"], RATES["logs_gb_month"]))
    add("CloudWatch alarms", RATES["alarms_month"], "~12 alarms, first 10 free")
    if cfg["container_insights"]:
        add("Container Insights (enhanced)", RATES["container_insights_month"], "1 cluster, 2 services, ~3 tasks")
    if cfg["scheduler"]:
        add("EventBridge Scheduler + cron Fargate job", RATES["scheduler_month"], "~10 min/day job")
    add("Route 53 hosted zone", 0.0 if cfg["cloudfront"] in ("free", "pro") else RATES["route53_zone_month"],
        "included in CloudFront Free/Pro plan" if cfg["cloudfront"] in ("free", "pro") else "$0.50/zone + queries")
    add("ECR + S3 state + misc", RATES["ecr_month"], "~1 GB images, state bucket")

    total = sum(i["monthly_usd"] for i in items)
    return items, round(total, 2), notes


def main(argv):
    a = parse_args(argv)
    cfg = dict(TIERS[a.tier])
    if a.cron: a.scheduler = True
    else: a.scheduler = None
    for k in ("tasks", "cpu", "memory", "db_class", "db_storage_gb", "multi_az", "nat", "cloudfront", "waf", "cache", "alb", "db", "spot_web", "scheduler",
              "alb_internal", "secrets", "logs_gb", "container_insights", "worker_tasks", "worker_spot", "kms", "s3_gb", "efs_gb",
              "migration_host"):
        v = getattr(a, k)
        if v is not None:
            cfg[k] = v
    if a.region != "us-east-1":
        region_note = "all numbers are us-east-1 LIST prices; %s is not priced here. eu-* and ap-* regions typically run 5-20%% higher (Fargate, RDS, data transfer); re-check the pricing pages for the target region" % a.region
    else:
        region_note = None
    items, total, notes = estimate(cfg)
    if region_note:
        notes.append(region_note)

    out = {
        "header": "Monthly AWS estimate - prices verified 2026-10-22 (us-east-1). Data transfer excluded.",
        "tier": a.tier, "region": a.region, "config": cfg, "items": items, "total_monthly_usd": total, "notes": notes,
    }
    if a.railway_monthly is not None:
        out["railway_monthly_usd"] = a.railway_monthly
        out["delta_monthly_usd"] = round(total - a.railway_monthly, 2)
        out["delta_yearly_usd"] = round((total - a.railway_monthly) * 12, 2)

    if a.json:
        print(json.dumps(out, indent=2))
        return 0

    print(out["header"])
    print("tier=%s region=%s  tasks=%d x %d/%dMB  workers=%d%s  db=%s%s  nat=%s  cloudfront=%s  cache=%s  alb=%s%s  kms=%s" % (
        a.tier, a.region, cfg["tasks"], cfg["cpu"], cfg["memory"], cfg["worker_tasks"], " (spot)" if cfg.get("worker_spot") else "",
        cfg["db_class"], " multi-az" if cfg["multi_az"] else "",
        cfg["nat"], cfg["cloudfront"], cfg["cache"], cfg["alb"], " internal" if cfg["alb_internal"] else "", cfg["kms"]))
    print()
    w = max(len(i["item"]) for i in items)
    print("%-*s  %10s  %s" % (w, "Item", "USD/month", "Detail"))
    print("%-*s  %10s  %s" % (w, "-" * w, "-" * 10, "-" * 6))
    for i in items:
        print("%-*s  %10.2f  %s" % (w, i["item"], i["monthly_usd"], i["detail"]))
    print("%-*s  %10s" % (w, "-" * w, "-" * 10))
    print("%-*s  %10.2f" % (w, "TOTAL (approx.)", total))
    if a.railway_monthly is not None:
        d = out["delta_monthly_usd"]
        print("%-*s  %10.2f" % (w, "Current Railway/Vercel bill", a.railway_monthly))
        print("%-*s  %+10.2f  (%+.0f/year)" % (w, "Delta (AWS - current)", d, d * 12))
    print()
    print("Excluded: internet egress ($0.09/GB after 100 GB), NAT data processing ($0.045/GB), cross-AZ ($0.01/GB), CloudFront requests beyond free tier, WAF request fees, support plans, taxes.")
    print("Most of the gap vs Railway is ALB hours + public IPv4 + the RDS instance, not compute. Closest to Railway pricing: --tier shared (one ALB and one RDS instance shared by N projects via the platform/ root, 0.25 vCPU task), optionally --spot-web. A dedicated ALB behind CloudFront (--alb-internal) drops two public IPv4s.")
    for n in notes:
        print("note: " + n)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
