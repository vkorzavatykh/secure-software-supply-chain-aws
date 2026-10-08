# GitHub Actions exchanges an OIDC token for short-lived AWS credentials, so no AWS access keys exist
# anywhere (ADR-005). Each role trusts this repository AND one event, branch or environment (security §3).
# Fork pull requests receive no OIDC token and can't assume any of them.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # No thumbprint_list: AWS validates this provider against its own library of trusted root CAs.
}

locals {
  github_subject = "repo:${var.github_repository}"

  ci_roles = {
    tf-plan = {
      description = "Terraform plan on pull requests: read-only infrastructure, read state, write the lock."
      subjects    = ["${local.github_subject}:pull_request"]
    }
    tf-apply = {
      description = "Terraform apply and destroy, only from jobs in the approved GitHub environment."
      subjects    = ["${local.github_subject}:environment:${var.github_environment}"]
    }
    dtrack = {
      description = "Reads the Dependency-Track CI API key for the SBOM upload and policy gate."
      subjects = [
        "${local.github_subject}:pull_request",
        "${local.github_subject}:ref:refs/heads/main",
      ]
    }
  }
}

data "aws_iam_policy_document" "github_trust" {
  for_each = local.ci_roles

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value.subjects
    }
  }
}

resource "aws_iam_role" "ci" {
  for_each = local.ci_roles

  name                 = "sssc-gha-${each.key}"
  description          = each.value.description
  assume_role_policy   = data.aws_iam_policy_document.github_trust[each.key].json
  max_session_duration = 3600
}
