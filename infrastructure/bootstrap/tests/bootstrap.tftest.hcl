# The CI roles' trust and permission policies are what keep the AWS account safe (security §3, ADR-019),
# so these tests read the policy JSON exactly as the real AWS provider renders it. The provider runs
# offline with fake credentials: every managed resource below is overridden, so nothing is ever sent to
# AWS, while the policy documents are still rendered by the provider itself.

provider "aws" {
  region                      = "eu-central-1"
  access_key                  = "offline-test"
  secret_key                  = "offline-test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "111111111111"
  }
}

# Resources other values depend on, with realistic identifiers.

override_resource {
  target = aws_s3_bucket.state
  values = {
    id  = "sssc-tfstate-111111111111"
    arn = "arn:aws:s3:::sssc-tfstate-111111111111"
  }
}

override_resource {
  target = aws_iam_openid_connect_provider.github
  values = {
    arn = "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"
  }
}

override_resource {
  target = aws_route53_zone.dtrack
  values = {
    zone_id = "Z0000000000000000000"
    arn     = "arn:aws:route53:::hostedzone/Z0000000000000000000"
  }
}

# The real provider knows the validation record names at plan time; the override must too.
override_resource {
  target          = aws_acm_certificate.dtrack
  override_during = plan
  values = {
    id                  = "arn:aws:acm:eu-central-1:111111111111:certificate/00000000-0000-0000-0000-000000000000"
    arn                 = "arn:aws:acm:eu-central-1:111111111111:certificate/00000000-0000-0000-0000-000000000000"
    region              = "eu-central-1"
    status              = "PENDING_VALIDATION"
    type                = "AMAZON_ISSUED"
    key_algorithm       = "RSA_2048"
    not_before          = ""
    not_after           = ""
    renewal_eligibility = "INELIGIBLE"
    domain_validation_options = [{
      domain_name           = "dtrack.frontward-solutions.com"
      resource_record_name  = "_0123456789abcdef.dtrack.frontward-solutions.com."
      resource_record_type  = "CNAME"
      resource_record_value = "_fedcba9876543210.acm-validations.aws."
    }]
  }
}

# Everything else only needs to stay away from AWS.

override_resource {
  target = aws_iam_role.ci
}

override_resource {
  target = aws_iam_role_policy_attachment.tf_plan_read_only
}

override_resource {
  target = aws_iam_role_policy.tf_plan
}

override_resource {
  target = aws_iam_role_policy.tf_apply
}

override_resource {
  target = aws_iam_role_policy.tf_apply_dns
}

override_resource {
  target = aws_iam_role_policy.dtrack
}

override_resource {
  target = aws_s3_bucket_ownership_controls.state
}

override_resource {
  target = aws_s3_bucket_public_access_block.state
}

override_resource {
  target = aws_s3_bucket_versioning.state
}

override_resource {
  target = aws_s3_bucket_server_side_encryption_configuration.state
}

override_resource {
  target = aws_s3_bucket_lifecycle_configuration.state
}

override_resource {
  target = aws_s3_bucket_policy.state
}

override_resource {
  target = aws_route53_record.caa
}

override_resource {
  target = aws_route53_record.certificate_validation
}

override_resource {
  target = aws_acm_certificate_validation.dtrack
}

run "each_ci_role_trusts_only_its_own_event" {
  command = apply

  assert {
    condition     = jsondecode(data.aws_iam_policy_document.github_trust["tf-plan"].json).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:vkorzavatykh/secure-software-supply-chain-aws:pull_request"
    error_message = "The plan role must trust pull requests of this repository only."
  }

  assert {
    condition     = jsondecode(data.aws_iam_policy_document.github_trust["tf-apply"].json).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:vkorzavatykh/secure-software-supply-chain-aws:environment:poc"
    error_message = "The apply role must trust jobs in the approved poc environment only."
  }

  assert {
    condition = toset(jsondecode(data.aws_iam_policy_document.github_trust["dtrack"].json).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"]) == toset([
      "repo:vkorzavatykh/secure-software-supply-chain-aws:pull_request",
      "repo:vkorzavatykh/secure-software-supply-chain-aws:ref:refs/heads/main",
    ])
    error_message = "The Dependency-Track role must trust pull requests and main only."
  }

  assert {
    condition = alltrue([
      for document in data.aws_iam_policy_document.github_trust : (
        jsondecode(document.json).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
        && jsondecode(document.json).Statement[0].Principal.Federated == aws_iam_openid_connect_provider.github.arn
        && !can(jsondecode(document.json).Statement[0].Condition.StringLike)
      )
    ])
    error_message = "Every CI role must require the STS audience, trust only the GitHub OIDC provider and use exact subject matches (no wildcards)."
  }

  assert {
    condition     = toset([for role in aws_iam_role.ci : role.name]) == toset(["sssc-gha-tf-plan", "sssc-gha-tf-apply", "sssc-gha-dtrack"])
    error_message = "Exactly the three documented CI roles must exist."
  }
}

run "terraform_roles_can_never_read_secret_values" {
  command = apply

  assert {
    condition = alltrue([
      for document in [data.aws_iam_policy_document.tf_plan.json, data.aws_iam_policy_document.tf_apply.json] :
      length([
        for statement in jsondecode(document).Statement : statement
        if statement.Effect == "Deny" && contains(flatten([statement.Action]), "secretsmanager:GetSecretValue") && contains(flatten([statement.Resource]), "*")
      ]) == 1
    ])
    error_message = "Both Terraform roles must explicitly deny reading any secret value."
  }

  assert {
    condition = alltrue([
      for document in [data.aws_iam_policy_document.tf_plan.json, data.aws_iam_policy_document.tf_apply.json] :
      length([
        for statement in jsondecode(document).Statement : statement
        if statement.Effect == "Deny" && contains(flatten([statement.Action]), "ssm:GetParameter")
        && contains(flatten([statement.Resource]), "arn:aws:ssm:eu-central-1:111111111111:parameter/sssc/dtrack/ci-api-key")
      ]) == 1
    ])
    error_message = "Both Terraform roles must explicitly deny reading the Dependency-Track CI API key (ADR-019, point 4)."
  }

  assert {
    condition = alltrue([
      for document in [data.aws_iam_policy_document.tf_plan.json, data.aws_iam_policy_document.tf_apply.json] :
      length([
        for statement in jsondecode(document).Statement : statement
        if statement.Effect == "Deny" && contains(flatten([statement.Action]), "ssm:GetParametersByPath") && contains(flatten([statement.Resource]), "*")
      ]) == 1
    ])
    error_message = "Both Terraform roles must deny recursive parameter reads, which would bypass the per-parameter deny."
  }
}

run "plan_role_reads_state_but_never_writes_it" {
  command = apply

  assert {
    condition = length([
      for statement in jsondecode(data.aws_iam_policy_document.tf_plan.json).Statement : statement
      if statement.Effect == "Allow" && contains(flatten([statement.Action]), "s3:PutObject") && contains(flatten([statement.Resource]), "arn:aws:s3:::sssc-tfstate-111111111111/poc/terraform.tfstate")
    ]) == 0
    error_message = "The plan role must not be able to write the state object."
  }

  assert {
    condition = length([
      for statement in jsondecode(data.aws_iam_policy_document.tf_plan.json).Statement : statement
      if statement.Effect == "Allow" && contains(flatten([statement.Action]), "s3:PutObject") && flatten([statement.Resource]) == ["arn:aws:s3:::sssc-tfstate-111111111111/poc/terraform.tfstate.tflock"]
    ]) == 1
    error_message = "The plan role must be able to take the state lock."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.tf_plan_read_only.policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess"
    error_message = "The plan role starts from ReadOnlyAccess (narrowed by the explicit denies)."
  }
}

run "apply_role_iam_rights_are_limited_to_the_instance_role" {
  command = apply

  assert {
    condition = alltrue(flatten([
      for statement in jsondecode(data.aws_iam_policy_document.tf_apply.json).Statement : [
        for resource in flatten([statement.Resource]) : contains([
          "arn:aws:iam::111111111111:role/sssc-ec2",
          "arn:aws:iam::111111111111:instance-profile/sssc-ec2",
          "arn:aws:iam::111111111111:role/aws-service-role/*",
        ], resource)
      ]
      if statement.Effect == "Allow" && anytrue([for action in flatten([statement.Action]) : startswith(action, "iam:")])
    ]))
    error_message = "IAM permissions of the apply role must target only sssc-ec2 (and service-linked roles); the CI roles themselves must be out of reach."
  }

  assert {
    condition = !anytrue([
      for statement in jsondecode(data.aws_iam_policy_document.tf_apply.json).Statement :
      anytrue([for action in flatten([statement.Action]) : contains(["*", "iam:*", "sts:*"], action)])
      if statement.Effect == "Allow"
    ])
    error_message = "The apply role must not be granted *, iam:* or sts:*."
  }

  assert {
    condition = one([
      for statement in jsondecode(data.aws_iam_policy_document.tf_apply.json).Statement : statement.Condition.StringEquals["iam:PassedToService"]
      if contains(flatten([statement.Action]), "iam:PassRole")
    ]) == "ec2.amazonaws.com"
    error_message = "The instance role may be passed to EC2 only."
  }

  assert {
    condition = one([
      for statement in jsondecode(data.aws_iam_policy_document.tf_apply.json).Statement : statement.Condition.ArnEquals["iam:PolicyARN"]
      if contains(flatten([statement.Action]), "iam:AttachRolePolicy")
    ]) == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    error_message = "The only managed policy the apply role may attach is AmazonSSMManagedInstanceCore."
  }
}

run "apply_role_may_change_only_the_apex_alias_record" {
  command = apply

  assert {
    condition = (
      jsondecode(data.aws_iam_policy_document.tf_apply_dns.json).Statement[0].Action == "route53:ChangeResourceRecordSets"
      && jsondecode(data.aws_iam_policy_document.tf_apply_dns.json).Statement[0].Resource == aws_route53_zone.dtrack.arn
      && jsondecode(data.aws_iam_policy_document.tf_apply_dns.json).Statement[0].Condition["ForAllValues:StringEquals"]["route53:ChangeResourceRecordSetsNormalizedRecordNames"] == "dtrack.frontward-solutions.com"
      && jsondecode(data.aws_iam_policy_document.tf_apply_dns.json).Statement[0].Condition["ForAllValues:StringEquals"]["route53:ChangeResourceRecordSetsRecordTypes"] == "A"
    )
    error_message = "Record changes must be limited to the A record at the zone apex."
  }
}

run "dtrack_role_reads_only_the_ci_key" {
  command = apply

  assert {
    condition     = length(jsondecode(data.aws_iam_policy_document.dtrack.json).Statement) == 2
    error_message = "The Dependency-Track role must have exactly two statements."
  }

  assert {
    condition = (
      jsondecode(data.aws_iam_policy_document.dtrack.json).Statement[0].Action == "ssm:GetParameter"
      && jsondecode(data.aws_iam_policy_document.dtrack.json).Statement[0].Resource == "arn:aws:ssm:eu-central-1:111111111111:parameter/sssc/dtrack/ci-api-key"
    )
    error_message = "The Dependency-Track role may read the CI API key parameter and nothing else."
  }

  assert {
    condition = (
      jsondecode(data.aws_iam_policy_document.dtrack.json).Statement[1].Action == "kms:Decrypt"
      && jsondecode(data.aws_iam_policy_document.dtrack.json).Statement[1].Condition.StringEquals["kms:ViaService"] == "ssm.eu-central-1.amazonaws.com"
      && jsondecode(data.aws_iam_policy_document.dtrack.json).Statement[1].Condition.StringEquals["kms:EncryptionContext:PARAMETER_ARN"] == "arn:aws:ssm:eu-central-1:111111111111:parameter/sssc/dtrack/ci-api-key"
    )
    error_message = "Decryption must be limited to that one parameter, through SSM."
  }
}

run "state_bucket_is_private_encrypted_and_versioned" {
  command = apply

  assert {
    condition = (
      aws_s3_bucket_public_access_block.state.block_public_acls
      && aws_s3_bucket_public_access_block.state.block_public_policy
      && aws_s3_bucket_public_access_block.state.ignore_public_acls
      && aws_s3_bucket_public_access_block.state.restrict_public_buckets
    )
    error_message = "All four public access blocks must be on."
  }

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "State must be versioned."
  }

  assert {
    condition     = tolist(aws_s3_bucket_server_side_encryption_configuration.state.rule)[0].apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "State must be encrypted at rest."
  }

  assert {
    condition = (
      jsondecode(data.aws_iam_policy_document.state_bucket.json).Statement[0].Effect == "Deny"
      && jsondecode(data.aws_iam_policy_document.state_bucket.json).Statement[0].Condition.Bool["aws:SecureTransport"] == "false"
    )
    error_message = "The bucket policy must refuse requests without TLS."
  }

  assert {
    condition     = aws_s3_bucket.state.force_destroy == false
    error_message = "The state bucket must not be destroyable with content by default."
  }
}

run "only_amazon_may_issue_certificates" {
  command = apply

  assert {
    condition     = aws_route53_record.caa.type == "CAA" && aws_route53_record.caa.records == toset(["0 issue \"amazon.com\""])
    error_message = "The CAA record must allow Amazon's CA only."
  }

  assert {
    condition     = aws_acm_certificate.dtrack.domain_name == "dtrack.frontward-solutions.com" && aws_acm_certificate.dtrack.validation_method == "DNS"
    error_message = "The certificate must cover the Dependency-Track hostname, validated by DNS."
  }
}
