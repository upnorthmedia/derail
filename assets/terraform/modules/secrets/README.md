# modules/secrets

Creates the AWS Secrets Manager entries an app needs, **without ever putting
a secret value through Terraform**. Think of it as creating empty, named
envelopes; a separate script puts the contents in.

On Railway/Vercel you typed `STRIPE_SECRET_KEY=sk_live_...` into a dashboard.
Here, the same variables live as one JSON object inside a Secrets Manager
secret called `<project>-<env>/app`, and ECS injects each key into the
container as an environment variable at start-up.

## What gets created

| Resource | Name | Purpose |
|---|---|---|
| `aws_secretsmanager_secret.app` | `<name>/app` | One JSON secret holding **all** app env vars: `{"DATABASE_URL": "...", "STRIPE_SECRET_KEY": "..."}`. |
| `aws_secretsmanager_secret.additional[*]` | `<name>/<key>` | Optional stand-alone secrets from `additional_secrets`. |

No `aws_secretsmanager_secret_version` is created. The value is written by
`scripts/put_secrets.sh` (which wraps `aws secretsmanager put-secret-value`),
and Terraform never reads it back.

## Cost

$0.40 per secret per month, plus $0.05 per 10,000 API calls. With the
default of one app secret that is **$0.40/month**; ECS reads the secret once
per task start, so API calls are negligible.

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `name` | **yes** | | Prefix, normally `<project>-<environment>`. |
| `kms_key_arn` | no | `null` | CMK for encryption; null = free AWS-managed key. |
| `recovery_window_in_days` | no | `30` | Undelete window (0, or 7-30). |
| `secret_keys` | no | `[]` | Env var names stored in the app secret (names only). |
| `additional_secrets` | no | `{}` | `key => description` for extra stand-alone secrets. |

## Outputs

| Name | Description |
|---|---|
| `app_secret_arn` | ARN of `<name>/app`. |
| `app_secret_name` | Its name; what `put_secrets.sh` targets. |
| `additional_secret_arns` | Map `key => ARN`. |
| `secret_arns` | All ARNs as a list, for the ECS execution role policy. |
| `ecs_secrets` | `[{ name = "KEY", valueFrom = "<arn>:KEY::" }, ...]` for the container definition. |

## How it is used from a root

```hcl
module "secrets" {
  source      = "../../../modules/secrets"
  name        = local.name
  secret_keys = var.secret_keys   # e.g. ["DATABASE_URL", "STRIPE_SECRET_KEY"]
}

module "web" {
  source      = "../../../modules/ecs_service"
  # ...
  secrets     = module.secrets.ecs_secrets
  secret_arns = module.secrets.secret_arns
}
```

Then, before the first deploy:

```sh
scripts/put_secrets.sh acme-prod/app   # prompts / reads a .env and writes the JSON
```

## Gotchas

- **Write the values before the first ECS deploy.** A secret with no value
  makes every task fail at start with
  `ResourceInitializationError: unable to pull secrets`. The root's default
  `image_tag = "bootstrap"` exists so you can apply the infrastructure, fill
  secrets, then deploy the real image.
- **ECS reads secrets only at task start.** After you rotate a value, run
  `aws ecs update-service --cluster <c> --service <s> --force-new-deployment`
  (or redeploy) or the running tasks keep the old value forever.
- **Every key in `secret_keys` must exist in the JSON.** If `valueFrom`
  names a key that is missing from the secret's JSON, the task fails to
  start. Keep `secret_keys` and the JSON in sync; `put_secrets.sh` validates
  this.
- **Deleted names are reserved during the recovery window.** If you destroy
  and re-apply within 30 days you get
  `You can't create this secret because a secret with this name is already scheduled for deletion`.
  Either wait, restore it, or
  `aws secretsmanager delete-secret --secret-id <name> --force-delete-without-recovery`.
- **Terraform does not know when values change.** That is the point, but it
  also means `terraform plan` will not tell you a secret is empty or stale.
- **Non-secret config does not belong here.** Plain settings (`NODE_ENV`,
  `NEXT_PUBLIC_*`, feature flags) go in the root's `plain_env` map and become
  normal container environment variables. Secrets Manager is for things you
  would not paste in a chat.
- **With a CMK (`kms_key_arn`)** the ECS *execution* role also needs
  `kms:Decrypt` on that key; `modules/ecs_service` adds it when it is given
  the same `kms_key_arn`.
