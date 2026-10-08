# None of these values is secret. They go into GitHub as repository variables (runbook §1).

output "state_bucket" {
  description = "S3 bucket that holds the poc environment's state (repository variable TF_STATE_BUCKET)."
  value       = aws_s3_bucket.state.bucket
}

output "tf_plan_role_arn" {
  description = "Role assumed by Terraform plan on pull requests (repository variable TF_PLAN_ROLE_ARN)."
  value       = aws_iam_role.ci["tf-plan"].arn
}

output "tf_apply_role_arn" {
  description = "Role assumed by apply and destroy in the poc environment (repository variable TF_APPLY_ROLE_ARN)."
  value       = aws_iam_role.ci["tf-apply"].arn
}

output "dtrack_role_arn" {
  description = "Role that reads the Dependency-Track CI API key (repository variable DTRACK_ROLE_ARN)."
  value       = aws_iam_role.ci["dtrack"].arn
}

output "dtrack_zone_name_servers" {
  description = "Add these as NS records for the subdomain at the parent domain's DNS provider, once (runbook §1)."
  value       = aws_route53_zone.dtrack.name_servers
}

output "dtrack_certificate_arn" {
  description = "ACM certificate for the Dependency-Track hostname; the environment finds it by domain name."
  value       = aws_acm_certificate_validation.dtrack.certificate_arn
}
