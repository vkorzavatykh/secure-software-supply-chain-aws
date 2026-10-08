# Instance role sssc-ec2 (security §3): Session Manager access plus exactly the secrets, parameters and
# log group the bootstrap needs. The secrets and parameters use AWS-managed KMS keys, whose key policies
# allow use through Secrets Manager and SSM, so no KMS statement is needed here.

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name_prefix}-ec2"
  description        = "Dependency-Track instance: SSM access, its own secrets and parameters, container logs"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance" {
  # Read at the moment of use by the bootstrap only, never copied into .env (ADR-022).
  statement {
    sid       = "ReadDatabaseMasterSecret"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.db_master_secret_arn]
  }

  statement {
    sid = "ManageDependencyTrackSecrets"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [for secret in aws_secretsmanager_secret.dtrack : secret.arn]
  }

  statement {
    sid       = "WriteBootstrapOutputs"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = [aws_ssm_parameter.bootstrap_status.arn, local.ci_api_key_arn]
  }

  statement {
    sid       = "WriteContainerLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "dependency-track-bootstrap"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "this" {
  name = aws_iam_role.instance.name
  role = aws_iam_role.instance.name
}
