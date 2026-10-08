output "address" {
  description = "Hostname of the database endpoint."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "PostgreSQL port."
  value       = aws_db_instance.this.port
}

output "identifier" {
  description = "RDS instance identifier (CloudWatch alarm dimension)."
  value       = aws_db_instance.this.identifier
}

output "master_user_secret_arn" {
  description = "ARN of the RDS-managed master secret. Readable only by the instance role, for bootstrap (ADR-022)."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "master_username" {
  description = "Master user name (not secret)."
  value       = aws_db_instance.this.username
}
