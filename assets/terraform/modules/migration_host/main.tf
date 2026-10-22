# migration_host: a throwaway EC2 instance inside the VPC for the data
# migration window. RDS and ElastiCache have no public endpoints, and pushing
# a multi-GB restore through a laptop uplink is slow and fragile, so pg_dump /
# pg_restore run from here:
#
#   old platform (public TCP, TLS)  -->  this host  -->  RDS / Valkey (private)
#
# Access is AWS Systems Manager Session Manager ONLY: no SSH daemon exposed, no
# key pair, no inbound security-group rule, no public port. Your laptop talks to
# the instance through the SSM API (`aws ssm start-session`), which also gives
# you a port forward to the database for GUI tools.
#
# Lifecycle: create it for the rehearsal and the cutover (root variable
# enable_migration_host = true), destroy it afterwards (false, apply). Cost
# while it exists: t4g.nano ~$3/month + 20 GiB gp3 ~$1.60/month.

data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  host_name = "${var.name}-migration-host"
  partition = data.aws_partition.current.partition
  region    = data.aws_region.current.region

  staging_prefix = trimprefix(var.staging_prefix, "/")
}

# Latest Amazon Linux 2023 AMI for the architecture, resolved through the
# public SSM parameter so no AMI id is hard-coded (ids differ per region and
# change monthly).
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${var.architecture}"
}

# ---------------------------------------------------------------------------
# Security group: nothing in, everything out
# ---------------------------------------------------------------------------

resource "aws_security_group" "this" {
  name        = local.host_name
  description = "Migration host ${var.name}: no inbound, SSM Session Manager only"
  vpc_id      = var.vpc_id

  tags = { Name = local.host_name }

  lifecycle {
    create_before_destroy = true
  }
}

# Outbound must reach: the SSM endpoints (443), dnf mirrors, the old platform's
# database proxy (any port), RDS (5432) and Valkey (6379) inside the VPC.
resource "aws_vpc_security_group_egress_rule" "all_ipv4" {
  security_group_id = aws_security_group.this.id
  description       = "All outbound (SSM, package repos, source database, RDS, Valkey)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "all_ipv6" {
  security_group_id = aws_security_group.this.id
  description       = "All outbound"
  cidr_ipv6         = "::/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# IAM: SSM agent + optional S3 staging + optional secret reads
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = local.host_name
  description        = "Temporary migration host for ${var.name}: SSM, optional S3 staging and secret reads"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = { Name = local.host_name }
}

# Everything Session Manager needs (ssm:UpdateInstanceInformation, ssmmessages:*,
# ec2messages:*). Without it the instance never appears as a managed node.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "extras" {
  count = var.staging_bucket_arn != null || length(var.readable_secret_arns) > 0 ? 1 : 0

  dynamic "statement" {
    for_each = var.staging_bucket_arn == null ? [] : [var.staging_bucket_arn]
    content {
      sid       = "ListStagingBucket"
      effect    = "Allow"
      actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
      resources = [statement.value]

      dynamic "condition" {
        for_each = local.staging_prefix == "" ? [] : [local.staging_prefix]
        content {
          test     = "StringLike"
          variable = "s3:prefix"
          values   = ["${condition.value}*"]
        }
      }
    }
  }

  dynamic "statement" {
    for_each = var.staging_bucket_arn == null ? [] : [var.staging_bucket_arn]
    content {
      sid    = "ReadWriteStagingObjects"
      effect = "Allow"
      actions = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts",
      ]
      resources = ["${statement.value}/${local.staging_prefix}*"]
    }
  }

  dynamic "statement" {
    for_each = length(var.readable_secret_arns) > 0 ? [1] : []
    content {
      sid       = "ReadMigrationSecrets"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      resources = var.readable_secret_arns
    }
  }
}

resource "aws_iam_role_policy" "extras" {
  count = length(data.aws_iam_policy_document.extras)

  name   = "migration-extras"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.extras[0].json
}

resource "aws_iam_instance_profile" "this" {
  name = local.host_name
  role = aws_iam_role.this.name

  tags = { Name = local.host_name }
}

# ---------------------------------------------------------------------------
# The instance
# ---------------------------------------------------------------------------

resource "aws_instance" "this" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = var.assign_public_ip
  ebs_optimized               = true
  monitoring                  = false # detailed monitoring costs $2.10/mo and tells us nothing useful here

  # No key_name on purpose: Session Manager is the only way in.

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gib
    encrypted             = true
    kms_key_id            = var.kms_key_arn
    delete_on_termination = true

    tags = { Name = local.host_name }
  }

  # PostgreSQL client tools for the TARGET major. Order of attempts:
  #   1. Amazon Linux 2023's own repo (postgresql15/16/17 exist there; newer
  #      majors appear a few months after release).
  #   2. The PGDG RPM repo built for RHEL 9 (same glibc family as AL2023).
  #   3. Neither worked: Docker is installed (install_docker) and the README
  #      shows the `docker run postgres:<major>` fallback.
  # The RDS CA bundle lands in /usr/local/share so `sslmode=verify-full` works.
  user_data = <<-EOT
    #!/bin/bash
    set -uxo pipefail
    PG_MAJOR=${var.pg_major}
    ARCH=$(uname -m)

    dnf -y install jq tar gzip zstd pv unzip

    if ! dnf -y install "postgresql$${PG_MAJOR}"; then
      cat > /etc/yum.repos.d/pgdg$${PG_MAJOR}.repo <<REPO
    [pgdg$${PG_MAJOR}]
    name=PostgreSQL $${PG_MAJOR} for RHEL 9 - $${ARCH} (used on Amazon Linux 2023)
    baseurl=https://download.postgresql.org/pub/repos/yum/$${PG_MAJOR}/redhat/rhel-9-$${ARCH}
    enabled=1
    gpgcheck=1
    gpgkey=https://download.postgresql.org/pub/repos/yum/keys/PGDG-RPM-GPG-KEY-RHEL
    REPO
      dnf -y install "postgresql$${PG_MAJOR}" || echo "WARNING: no postgresql$${PG_MAJOR} client package available; use the Docker fallback from the module README" >&2
      # PGDG installs to /usr/pgsql-<major>/bin, which is not on PATH for ssm-user.
      if [ -d "/usr/pgsql-$${PG_MAJOR}/bin" ]; then
        echo "export PATH=/usr/pgsql-$${PG_MAJOR}/bin:\$PATH" > /etc/profile.d/pgdg.sh
      fi
    fi

    %{if var.install_docker}
    dnf -y install docker && systemctl enable --now docker && usermod -aG docker ssm-user 2>/dev/null || true
    %{endif}

    curl -fsSL -o /usr/local/share/rds-global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
    install -d -m 0777 /opt/migration
    echo "migration host ready: $(date -u)" > /opt/migration/READY
  EOT

  # A change to the bootstrap script replaces the instance (it is disposable).
  user_data_replace_on_change = true

  tags = { Name = local.host_name }
}
