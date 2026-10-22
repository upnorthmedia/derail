output "address" {
  description = "DNS hostname of the instance (use this in DATABASE_URL)."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "TCP port the database listens on (5432)."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Name of the initial database."
  value       = aws_db_instance.this.db_name
}

output "master_username" {
  description = "Master user name. The password is only in the RDS-managed secret."
  value       = aws_db_instance.this.username
}

output "master_user_secret_arn" {
  description = "ARN of the RDS-managed Secrets Manager secret holding {username, password} for the master user. The ARN is not sensitive; the value never enters Terraform."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "security_group_id" {
  description = "Security group attached to the instance (add more ingress rules to it for bastions etc.)."
  value       = aws_security_group.this.id
}

output "instance_identifier" {
  description = "RDS instance identifier (for aws rds CLI commands)."
  value       = aws_db_instance.this.identifier
}

output "instance_arn" {
  description = "ARN of the RDS instance (for IAM policies and AWS Backup selections)."
  value       = aws_db_instance.this.arn
}
