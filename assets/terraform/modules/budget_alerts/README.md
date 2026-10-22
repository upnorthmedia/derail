# modules/budget_alerts

Per-project cost guardrails: an SNS topic you can route any alarm to, a
monthly budget that emails you before the month gets expensive, and a Cost
Anomaly Detection monitor that tells you *which project* just started
burning money.

Railway shows one bill per project. AWS shows one bill per account. This
module (together with the `Project` tag the root puts on everything) is what
gives you the per-project view back.

## What gets created

| Resource | Name | Purpose |
|---|---|---|
| `aws_sns_topic` + email subscription | `<name>-alerts` | Delivery channel. RDS/ECS CloudWatch alarms from the other modules should point at it. |
| `aws_sns_topic_policy` | | Lets `budgets.amazonaws.com` and `costalerts.amazonaws.com` publish. |
| `aws_budgets_budget` | `<name>-monthly` | COST budget filtered on `Project=<project>`; emails at 80% actual and 100% forecast. |
| `aws_ce_anomaly_monitor` (optional) | `<name>-anomalies` | CUSTOM monitor on the `Project` tag. |
| `aws_ce_anomaly_subscription` (optional) | `<name>-anomalies` | IMMEDIATE alert to the topic when an anomaly's impact is at least `anomaly_threshold_usd`. |

## Cost

**$0/month.** Budget notifications, Anomaly Detection and the first 1,000 SNS
emails per month are free. (Budget *actions* that stop instances would cost
$0.10/day each; this module does not create any.)

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `name` | **yes** | | Prefix, normally `<project>-<environment>`. |
| `project` | **yes** | | The `Project` tag value to filter on. |
| `alert_email` | **yes** | | Recipient. |
| `monthly_budget_usd` | **yes** | | Monthly budget for this project. |
| `anomaly_threshold_usd` | no | `10` | Minimum anomaly impact before alerting. |
| `create_anomaly_monitor` | no | `true` | Create the anomaly monitor + subscription. |

## Outputs

| Name | Description |
|---|---|
| `alerts_topic_arn` | SNS topic ARN; pass to `rds_postgres` / `ecs_service` as `alarm_topic_arn`. |
| `budget_name` | Budget name. |
| `anomaly_monitor_arn` | Monitor ARN or `null`. |

## How it is used from a root

```hcl
module "budget_alerts" {
  source             = "../../../modules/budget_alerts"
  name               = local.name
  project            = var.project
  alert_email        = var.alert_email
  monthly_budget_usd = var.monthly_budget_usd
}
```

## Gotchas

- **The budget sees nothing until the `Project` tag is activated** as a
  cost-allocation tag (done in `bootstrap/` with
  `activate_cost_allocation_tags = true`, ~24h after resources first exist).
  Until then the budget reports $0 spent, which looks reassuring and is
  wrong. Costs before activation are never attributed.
- **Confirm the SNS subscription email**, or anomaly alerts (and every
  CloudWatch alarm routed to the topic) go nowhere. Budget emails are sent
  directly by AWS Budgets and need no confirmation.
- **Anomaly detection needs ~10 days of history** before it can flag
  anything, and it lags real spend by up to 24h. It will not catch a runaway
  job the same afternoon; the budget's forecast alert is the faster signal.
- **Budgets are evaluated a few times per day**, not continuously.
- **Untagged costs are invisible to this budget.** Data transfer, public
  IPv4 on task ENIs and anything created by hand in the console shows up
  under the account-wide budget in `bootstrap/` instead. Expect 5-15% of a
  small account to be unattributed.
- **Tag values are case-sensitive.** `project` here must be byte-identical
  to the root's `var.project`.
- **Budget names are unique per account.** Two roots with the same `name`
  would collide; the `<project>-<environment>` convention avoids that.
- **Budgets/Cost Explorer resources are global** and only exist in
  `us-east-1` behind the scenes; the provider handles that, you do not need
  a second provider.
