output "instance_id" {
  description = "ID of the Dependency-Track instance (target for SSM sessions and the load balancer)."
  value       = aws_instance.this.id
}

output "instance_role_name" {
  description = "Name of the instance role."
  value       = aws_iam_role.instance.name
}

output "log_group_name" {
  description = "CloudWatch log group of the containers."
  value       = aws_cloudwatch_log_group.this.name
}

output "secret_names" {
  description = "Secrets Manager secrets whose values the instance writes, keyed admin, db-app and secret-key."
  value       = { for key, secret in aws_secretsmanager_secret.dtrack : key => secret.name }
}

output "bootstrap_status_parameter" {
  description = "SSM parameter that reads \"done\" once the default Dependency-Track login is verified to fail."
  value       = aws_ssm_parameter.bootstrap_status.name
}

output "ci_api_key_parameter" {
  description = "SSM parameter the instance writes the CI API key to. Not managed by Terraform (see main.tf)."
  value       = "${var.dtrack_parameter_path}/ci-api-key"
}
