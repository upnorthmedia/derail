output "alb_arn" {
  description = "ARN of the load balancer."
  value       = aws_lb.this.arn
}

output "alb_arn_suffix" {
  description = "ARN suffix (app/<name>/<id>) used as the LoadBalancer dimension in CloudWatch metrics and in autoscaling resource labels."
  value       = aws_lb.this.arn_suffix
}

output "alb_dns_name" {
  description = "Public DNS name of the ALB (CloudFront origin, or CNAME target when create_dns_record = false)."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "Route 53 hosted zone ID of the ALB, for alias records created elsewhere."
  value       = aws_lb.this.zone_id
}

output "https_listener_arn" {
  description = "ARN of the :443 listener. Services attach aws_lb_listener_rule resources to it."
  value       = aws_lb_listener.https.arn
}

output "security_group_id" {
  description = "ALB security group ID. Task security groups should allow their container port from this SG only."
  value       = aws_security_group.this.id
}

output "certificate_arn" {
  description = "ARN of the validated ACM certificate."
  value       = aws_acm_certificate_validation.this.certificate_arn
}
