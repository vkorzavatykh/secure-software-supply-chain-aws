output "url" {
  description = "Public URL of Dependency-Track."
  value       = "https://${var.domain_name}"
}

output "alb_dns_name" {
  description = "DNS name of the load balancer."
  value       = aws_lb.this.dns_name
}

output "alb_arn_suffix" {
  description = "ARN suffix of the load balancer (CloudWatch alarm dimension)."
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn_suffixes" {
  description = "ARN suffix of each target group, keyed ui and api (CloudWatch alarm dimension)."
  value       = { for name, group in aws_lb_target_group.this : name => group.arn_suffix }
}

output "dtrack_public" {
  description = "Whether the HTTPS listener forwards to Dependency-Track (true) or answers 503 (false)."
  value       = var.dtrack_public
}
