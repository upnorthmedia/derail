# bootstrap

Run this **once per AWS account**, by a human with administrator credentials,
before anything else. It creates the account-level plumbing that every other
root depends on. After it has been applied you should never need to touch it
again except to raise the budget.

If you have never used Terraform: a "root" is just a folder you `cd` into and
run `terraform apply` in. Terraform reads the `.tf` files, works out what is
missing in AWS, shows you the plan, and creates it after you type `yes`. It
remembers what it created in a *state file*; this root creates the bucket
that holds everyone else's state files, which is why it has to go first.

## What gets created

| Resource | Why |
|---|---|
| S3 bucket `tfstate-<account-id>-<region>` | Holds the Terraform state of every root. Versioned (90 days of history), encrypted, public access blocked, TLS-only bucket policy, `prevent_destroy`. |
| IAM OIDC provider for `token.actions.githubusercontent.com` | Lets GitHub Actions assume roles with short-lived credentials. No access keys anywhere. One per account; disable with `enable_github_oidc = false` if it already exists. |
| Cost-allocation tag activation for `Project`, `Environment`, `ManagedBy`, `Repository` | Makes "cost per project" possible in Cost Explorer. Off by default on the first apply, see gotchas. |
| SNS topic `platform-alerts` + email subscription | Where account-wide cost anomalies land. Click the confirmation email. |
| Monthly budget (account-wide) | Email at 80% actual spend and when the forecast crosses 100%. |
| Cost Anomaly Detection monitor (per AWS service) + immediate SNS alert | Catches "why is NAT suddenly $90" within a day. |

## Cost

Effectively **$0/month**. State files are kilobytes (S3 ~$0.023/GB), SNS
email is free for the first 1,000 notifications, Budgets notifications and
Anomaly Detection are free. SSE-KMS on the bucket (optional) adds roughly
$1/month for the key plus a few cents in requests.

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `aws_region` | no | `us-east-1` | Region for the bucket and topic. |
| `project` | no | `platform` | Project tag / name prefix for bootstrap resources. |
| `environment` | no | `prod` | Environment tag (`dev`, `staging`, `prod`). |
| `repository` | **yes** | | `github.com/org/repo` holding this code; becomes the `Repository` tag. |
| `alert_email` | **yes** | | Receives budget and anomaly emails. |
| `alerts_topic_name` | no | `platform-alerts` | SNS topic name. |
| `monthly_budget_usd` | **yes** | | Whole-account monthly budget. |
| `anomaly_threshold_usd` | no | `10` | Minimum anomaly impact (USD) before you are alerted. |
| `state_kms_key_arn` | no | `null` | Use SSE-KMS with this key instead of SSE-S3. |
| `enable_github_oidc` | no | `true` | Create the GitHub OIDC provider. |
| `activate_cost_allocation_tags` | no | `false` | Activate the four tag keys for billing (second apply, see below). |

## Outputs

| Name | Description |
|---|---|
| `state_bucket` | Bucket name to put in every other root's `backend.tf`. |
| `state_bucket_arn` | Bucket ARN, input to `modules/github_oidc_roles`. |
| `oidc_provider_arn` | Input to `modules/github_oidc_roles` (`null` if disabled). |
| `alerts_topic_arn` | Account-wide SNS topic. |
| `account_id`, `aws_region` | For filling in backend blocks. |
| `backend_config_snippet` | A backend block you can paste into other roots. |

## How to run

```sh
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # edit the values
terraform init                                  # downloads the AWS provider
terraform plan                                  # read it; nothing is changed yet
terraform apply                                 # type "yes"
```

Use your normal admin credentials (`aws login` / SSO / an admin profile).
This is the only root that needs them.

### Move the bootstrap state into the bucket it just created

The first apply stores state in a local `terraform.tfstate` file, because the
bucket did not exist yet. Move it:

```sh
cp backend.tf.example backend.tf      # fill in bucket + region from `terraform output`
terraform init -migrate-state         # answer "yes"
terraform state list                  # should still list every resource
rm terraform.tfstate terraform.tfstate.backup
```

From now on `terraform plan` in this folder reads state from S3. Keep
`backend.tf` committed; it contains nothing secret.

### Second apply: activate cost-allocation tags

About 24 hours after the first apply, set `activate_cost_allocation_tags = true`
in `terraform.tfvars` and `terraform apply` again. Then another day or so
later, Cost Explorer can group by the `Project` tag.

## Gotchas

- **Cost-allocation tags are not retroactive and appear late.** AWS only
  lists a tag key for activation up to 24h after a tagged resource first
  exists, and only attributes costs from activation onwards. That is why the
  activation is a separate, second apply. If the apply fails with
  "reading Cost Explorer Cost Allocation Tag ... empty result", it is too
  early; wait and retry.
- **Confirm the SNS email.** Until you click the link, anomaly alerts go
  nowhere. Budget emails are sent directly by AWS Budgets and need no
  confirmation.
- **One OIDC provider per account.** If `terraform apply` says the provider
  already exists, either import it
  (`terraform import 'aws_iam_openid_connect_provider.github[0]' arn:aws:iam::<acct>:oidc-provider/token.actions.githubusercontent.com`)
  or set `enable_github_oidc = false` and pass the existing ARN to the project
  roots yourself.
- **Anomaly detection needs history.** Expect no anomaly alerts for the first
  ~10 days of a new account or new service; it is learning the baseline.
- **Budgets are evaluated a few times a day**, not in real time. They are a
  safety net, not a circuit breaker.
- **The bucket cannot be destroyed by Terraform** (`prevent_destroy`). To
  decommission the account, delete the lifecycle block, empty the bucket
  (all versions), then destroy. This is deliberate friction.
- **CI roles must never write `bootstrap/*`.** `modules/github_oidc_roles`
  denies that prefix explicitly. Only humans apply this root.
- **Do not use `terraform workspace`** to separate projects; each project
  gets its own folder and its own state key instead.
