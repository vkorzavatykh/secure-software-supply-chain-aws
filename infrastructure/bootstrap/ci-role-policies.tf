# Permissions of the three CI roles (security §3). The apply role starts at service level and is narrowed
# from what Terraform actually calls; it is "scoped, not minimal" (security §3, least-privilege note).

locals {
  arn_prefix_regional = "arn:${local.partition}:%s:${var.region}:${local.account_id}"

  # The environment's only IAM role and instance profile. The apply role may manage exactly these.
  instance_role_name = "sssc-ec2"
  instance_role_arn  = "arn:${local.partition}:iam::${local.account_id}:role/${local.instance_role_name}"
  ssm_core_policy    = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# --- Shared: never read Dependency-Track secrets --------------------------------------------------------
# Terraform only manages the secret containers; the instance writes the values (security §4). Explicit
# denies win over any allow, including the ReadOnlyAccess policy on the plan role.

data "aws_iam_policy_document" "deny_secret_values" {
  statement {
    sid       = "DenySecretValues"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:BatchGetSecretValue"]
    resources = ["*"]
  }

  statement {
    sid    = "DenyDependencyTrackParameters"
    effect = "Deny"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParameterHistory",
    ]
    resources = [local.dtrack_ci_api_key_arn]
  }

  # A recursive read from "/" would otherwise return those parameters too. Terraform doesn't need it.
  statement {
    sid       = "DenyParameterPathReads"
    effect    = "Deny"
    actions   = ["ssm:GetParametersByPath"]
    resources = ["*"]
  }
}

# --- sssc-gha-tf-plan ---------------------------------------------------------------------------------

resource "aws_iam_role_policy_attachment" "tf_plan_read_only" {
  role       = aws_iam_role.ci["tf-plan"].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "tf_plan" {
  source_policy_documents = [data.aws_iam_policy_document.deny_secret_values.json]

  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  # A plan reads state but never writes it. It only needs to take and release the lock.
  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.state.arn}/${local.poc_state_key}"]
  }

  statement {
    sid       = "ManageStateLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/${local.poc_state_key}.tflock"]
  }
}

resource "aws_iam_role_policy" "tf_plan" {
  name   = "terraform-plan"
  role   = aws_iam_role.ci["tf-plan"].id
  policy = data.aws_iam_policy_document.tf_plan.json
}

# --- sssc-gha-tf-apply --------------------------------------------------------------------------------

data "aws_iam_policy_document" "tf_apply" {
  source_policy_documents = [data.aws_iam_policy_document.deny_secret_values.json]

  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "ReadWriteState"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/${local.poc_state_key}"]
  }

  statement {
    sid       = "ManageStateLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/${local.poc_state_key}.tflock"]
  }

  # Network, compute, load balancer, database and alarms. Service level for now, region-locked.
  statement {
    sid = "ManageEnvironmentServices"
    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "rds:*",
      "cloudwatch:*",
      "acm:DescribeCertificate",
      "acm:GetCertificate",
      "acm:ListCertificates",
      "acm:ListTagsForCertificate",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "ManageProjectLogGroups"
    actions   = ["logs:*"]
    resources = ["${format(local.arn_prefix_regional, "logs")}:log-group:/sssc/*"]
  }

  statement {
    sid       = "DescribeLogGroups"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    sid       = "ManageAlarmTopics"
    actions   = ["sns:*"]
    resources = ["${format(local.arn_prefix_regional, "sns")}:sssc-*"]
  }

  statement {
    sid = "ManageProjectParameters"
    actions = [
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      "ssm:DeleteParameters",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
      "ssm:ListTagsForResource",
    ]
    resources = ["${format(local.arn_prefix_regional, "ssm")}:parameter/sssc/*"]
  }

  statement {
    sid       = "ReadPublicAmiParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:${local.partition}:ssm:${var.region}::parameter/aws/service/*"]
  }

  statement {
    sid       = "DescribeParameters"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  # Secret containers only (values are written by the instance), plus the RDS-managed master secret,
  # which RDS creates on the caller's behalf (ADR-010).
  statement {
    sid = "ManageSecretContainers"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:DescribeSecret",
      "secretsmanager:UpdateSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:PutResourcePolicy",
      "secretsmanager:DeleteResourcePolicy",
      "secretsmanager:RotateSecret",
      "secretsmanager:CancelRotateSecret",
    ]
    resources = [
      "${format(local.arn_prefix_regional, "secretsmanager")}:secret:sssc/*",
      "${format(local.arn_prefix_regional, "secretsmanager")}:secret:rds!*",
    ]
  }

  # AWS-managed keys for encrypted EBS, RDS storage and secrets, used only through those services.
  statement {
    sid = "UseKeysThroughServices"
    actions = [
      "kms:DescribeKey",
      "kms:CreateGrant",
      "kms:Decrypt",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values = [
        "ec2.${var.region}.amazonaws.com",
        "rds.${var.region}.amazonaws.com",
        "secretsmanager.${var.region}.amazonaws.com",
      ]
    }
  }

  # IAM is the escalation path, so it is the tightest part: exactly one role and instance profile, one
  # attachable managed policy, and PassRole only to EC2. The CI roles themselves are out of reach.
  statement {
    sid = "ManageInstanceRole"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRolePolicies",
      "iam:GetRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
    ]
    resources = [
      local.instance_role_arn,
      "arn:${local.partition}:iam::${local.account_id}:instance-profile/${local.instance_role_name}",
    ]
  }

  statement {
    sid       = "AttachOnlySsmCorePolicy"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = [local.instance_role_arn]

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = [local.ssm_core_policy]
    }
  }

  statement {
    sid       = "PassInstanceRoleToEc2Only"
    actions   = ["iam:PassRole"]
    resources = [local.instance_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # Created by AWS on first use of ELB and RDS in a new account.
  statement {
    sid       = "CreateServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["elasticloadbalancing.amazonaws.com", "rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "tf_apply" {
  name   = "terraform-apply"
  role   = aws_iam_role.ci["tf-apply"].id
  policy = data.aws_iam_policy_document.tf_apply.json
}

# --- sssc-gha-dtrack ----------------------------------------------------------------------------------

data "aws_iam_policy_document" "dtrack" {
  statement {
    sid       = "ReadCiApiKey"
    actions   = ["ssm:GetParameter"]
    resources = [local.dtrack_ci_api_key_arn]
  }

  # Decrypt only through SSM, and only for that one parameter (SSM's encryption context).
  statement {
    sid       = "DecryptCiApiKeyThroughSsm"
    actions   = ["kms:Decrypt"]
    resources = ["${format(local.arn_prefix_regional, "kms")}:key/*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:PARAMETER_ARN"
      values   = [local.dtrack_ci_api_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "dtrack" {
  name   = "dependency-track-ci-key"
  role   = aws_iam_role.ci["dtrack"].id
  policy = data.aws_iam_policy_document.dtrack.json
}
