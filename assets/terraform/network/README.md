# network

The one VPC that every project in this AWS account shares. Apply it **once per
account**, after `bootstrap/` and before the optional `platform/` root and any
`live/<project>/<env>/` root.

Railway and Vercel hide networking from you. On AWS, every container and
database must live in a VPC (a private network you own) and a subnet inside
it. This root builds a small, conventional one and tags it so project roots
can find it without any wiring between them.

## What gets created

| Resource | Notes |
|---|---|
| VPC `<platform_name>-vpc`, CIDR `10.0.0.0/16` by default | DNS hostnames and support enabled. |
| 2 public subnets (one per AZ), tagged `Tier = public` | Route to the internet gateway; instances get public IPs. ALBs and no-NAT ECS tasks live here. |
| 2 private subnets (one per AZ), tagged `Tier = private` | No inbound from the internet. RDS lives here. Outbound only through a NAT gateway (off by default). |
| Internet gateway, route tables, associations | Created by the module. |
| S3 gateway VPC endpoint | Free. Keeps S3/ECR-layer traffic private and off the NAT. |
| NAT gateway (optional, `enable_nat_gateway`) | **~$33/month + $0.045/GB**, even when idle. Off by default. |
| Elastic IP `<platform_name>-nat-egress` (optional, `stable_nat_eip`) | Our own `prevent_destroy` EIP handed to the NAT gateway, so the egress address never changes. Free while attached. |
| VPC flow logs to CloudWatch (optional, `enable_flow_logs`) | 30-day retention, ~$0.50/GB ingested. Off by default. |

The VPC itself, subnets, route tables, IGW and the S3 endpoint are **free**.

## Rough monthly cost

| Setting | Cost |
|---|---|
| Defaults (no NAT, no flow logs) | **$0** |
| `enable_nat_gateway = true` | ~$33 + data processing |
| `enable_flow_logs = true` | typically $1-5 for a small app |

Why no NAT by default: the project roots run ECS tasks in the public subnets
with a public IP (`task_in_public_subnets = true`), which lets them pull
images and reach the internet for ~$3.60/month per task in public-IPv4
charges instead of $33 flat. The tasks are still protected by their security
group (only the load balancer may talk to them). Turn NAT on when you want
tasks with no public IP at all, or when you have more than ~8 tasks and the
IPv4 charges overtake the NAT price.

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `platform_name` | no | `platform` | Name/tag prefix. Project roots must use the same value. |
| `environment` | no | `prod` | Environment tag. |
| `repository` | **yes** | | `github.com/org/repo` (Repository tag). |
| `aws_region` | no | `us-east-1` | Must match the project roots. |
| `vpc_cidr` | no | `10.0.0.0/16` | VPC range; four /20 subnets are carved from it. |
| `enable_nat_gateway` | no | `false` | Single NAT gateway (~$33/mo). |
| `enable_flow_logs` | no | `false` | Flow logs to CloudWatch. |
| `stable_nat_eip` | no | `false` | Own the NAT EIP (`prevent_destroy`) so the egress IP survives NAT rebuilds. Needs `enable_nat_gateway`. |

## Outputs

| Name | Description |
|---|---|
| `vpc_id` | VPC id. |
| `vpc_cidr_block` | VPC CIDR. |
| `public_subnet_ids` | The two public subnet ids. |
| `private_subnet_ids` | The two private subnet ids. |
| `nat_public_ips` | NAT egress IPs (empty when NAT is off). The stable EIP when `stable_nat_eip = true`. |
| `stable_nat_eip_allocation_ids` | Allocation ids of the owned EIP(s); empty otherwise. |
| `availability_zones` | AZs used. |
| `s3_endpoint_id` | Gateway endpoint id. |

## How project roots find this VPC

They do **not** read this root's state. They use data sources filtered by
tags, which is why the tags matter:

```hcl
data "aws_vpc" "shared" {
  filter {
    name   = "tag:Name"
    values = ["${var.platform_name}-vpc"]
  }
}
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.shared.id]
  }
  filter {
    name   = "tag:Tier"
    values = ["public"]
  }
}
```

## How to run

```sh
cd network
# edit backend.tf: bucket and region from `terraform -chdir=../bootstrap output`
cp terraform.tfvars.example terraform.tfvars   # edit
terraform init
terraform plan
terraform apply
```

## Gotchas

- **Edit `backend.tf` first.** It ships with a placeholder account id.
  `terraform init` will fail (or worse, succeed against the wrong bucket) if
  you skip this.
- **Changing `vpc_cidr` later recreates the VPC**, and everything in it. Pick
  a range now that does not overlap with anything you might VPN/peer to
  later (your office network, another cloud). `10.0.0.0/16` collides with a
  lot of home routers and Docker defaults; if that matters, use e.g.
  `10.42.0.0/16`.
- **Private subnets have no internet without NAT.** An ECS task placed in a
  private subnet with `enable_nat_gateway = false` will fail to start with
  `ResourceInitializationError: unable to pull registry auth`. Either keep
  tasks in public subnets or enable NAT.
- **Two AZs, picked automatically.** The first two "available" AZs in the
  region are used. Resources in them are not movable; do not change the AZ
  logic after apply.
- **Turning NAT off after it was on** also removes the Elastic IP; third
  parties that allow-listed it must be told. With `stable_nat_eip = true` the
  EIP is `prevent_destroy` and the plan fails instead; delete the lifecycle
  block deliberately if you really want to release the address.
- **`stable_nat_eip` on an existing NAT gateway** swaps the module-owned EIP
  for ours, which replaces the gateway once (a minute of egress outage and a
  new IP). Do it before you give the IP to anyone, or in a maintenance window.
- **Do not add project-specific things here.** Security groups, endpoints
  for one app, etc. belong in that project's root so a client can be removed
  cleanly.
