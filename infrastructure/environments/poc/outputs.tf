output "dtrack_url" {
  description = "Public URL of Dependency-Track. It answers 503 until dtrack_public is true (ADR-020)."
  value       = module.edge.url
}

output "dtrack_public" {
  description = "Whether the load balancer forwards to Dependency-Track."
  value       = module.edge.dtrack_public
}

output "alb_dns_name" {
  description = "DNS name of the load balancer."
  value       = module.edge.alb_dns_name
}

output "instance_id" {
  description = "Dependency-Track instance, for aws ssm start-session (runbook §5)."
  value       = module.compute.instance_id
}

output "bootstrap_status_parameter" {
  description = "SSM parameter to poll before opening the startup barrier; reads done when bootstrap has verified the credentials."
  value       = module.compute.bootstrap_status_parameter
}

output "admin_secret_name" {
  description = "Secrets Manager secret with the Dependency-Track admin password."
  value       = module.compute.secret_names["admin"]
}

output "ci_api_key_parameter" {
  description = "SSM parameter with the CI API key, written by the instance and deleted by the destroy job."
  value       = module.compute.ci_api_key_parameter
}

output "log_group_name" {
  description = "CloudWatch log group of the containers (aws logs tail)."
  value       = module.compute.log_group_name
}
