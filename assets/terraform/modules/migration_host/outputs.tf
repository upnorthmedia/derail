output "instance_id" {
  description = "EC2 instance id (the --target of every ssm start-session command)."
  value       = aws_instance.this.id
}

output "security_group_id" {
  description = "Security group of the host. The root adds it to the RDS and Valkey allowed lists so the host can reach them."
  value       = aws_security_group.this.id
}

output "role_arn" {
  description = "IAM role the instance runs as."
  value       = aws_iam_role.this.arn
}

output "session_command" {
  description = "Open an interactive shell on the host (needs the Session Manager plugin: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)."
  value       = "aws ssm start-session --region ${local.region} --target ${aws_instance.this.id}"
}

output "port_forward_commands" {
  description = "One `aws ssm start-session` port-forward command per entry of port_forward_hosts: connect your laptop's localhost:<local_port> to <host>:<port> through the instance."
  value = {
    for k, v in var.port_forward_hosts : k => join(" ", [
      "aws ssm start-session --region ${local.region} --target ${aws_instance.this.id}",
      "--document-name AWS-StartPortForwardingSessionToRemoteHost",
      "--parameters '${jsonencode({ host = [v.host], portNumber = [tostring(v.port)], localPortNumber = [tostring(v.local_port)] })}'",
    ])
  }
}

output "pg_major" {
  description = "PostgreSQL client major the host was asked to install."
  value       = var.pg_major
}
