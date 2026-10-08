# One-time stack, applied from a workstation with admin SSO credentials (ADR-005, ADR-008).
# It creates what CI can't create for itself: the state bucket, the GitHub OIDC identity provider and the
# CI roles. The DNS zone and certificate live here too, because they must survive every environment
# teardown (ADR-011).

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # Terraform state of the per-session environment and its S3-native lock file.
  poc_state_key = "poc/terraform.tfstate"

  # Parameters the CI infrastructure roles must never read (security §3, ADR-019).
  dtrack_ci_api_key_arn  = "arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter/sssc/dtrack/ci-api-key"
  dtrack_nvd_api_key_arn = "arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter/sssc/dtrack/nvd-api-key"
}
