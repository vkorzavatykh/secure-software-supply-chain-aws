# Offline tests with a mocked AWS provider: instance hardening (ADR-004, architecture §6) and the
# ownership rules that keep secrets out of state and the startup barrier honest (ADR-020, ADR-021).

mock_provider "aws" {
  mock_data "aws_ssm_parameter" {
    defaults = {
      insecure_value = "ami-0123456789abcdef0"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "eu-central-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111"
    }
  }

  # The provider validates policy JSON; the documents' content is not under test here.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
}

variables {
  subnet_id            = "subnet-0aaaaaaaaaaaaaaaa"
  security_group_id    = "sg-0123456789abcdef0"
  user_data_base64     = "H4sIAAAAAAAA/0tMSU1JTVUoSs0rzszPK0nNyywBANqJjVENAAAA"
  db_master_secret_arn = "arn:aws:secretsmanager:eu-central-1:111111111111:secret:rds!db-00000000-0000-0000-0000-000000000000-AbCdEf"
}

run "instance_is_hardened" {
  command = plan

  assert {
    condition     = aws_instance.this.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required."
  }

  assert {
    condition     = aws_instance.this.metadata_options[0].http_put_response_hop_limit == 2
    error_message = "The hop limit must be 2, so containers can use the instance role."
  }

  assert {
    condition     = aws_instance.this.associate_public_ip_address == false
    error_message = "The instance must not get a public IP."
  }

  assert {
    condition     = aws_instance.this.root_block_device[0].encrypted && aws_instance.this.root_block_device[0].volume_type == "gp3"
    error_message = "The root volume must be encrypted gp3."
  }

  assert {
    condition     = aws_instance.this.user_data_replace_on_change
    error_message = "A bootstrap change must replace the instance (ADR-009)."
  }

  assert {
    condition     = aws_instance.this.ami == "ami-0123456789abcdef0"
    error_message = "The AMI must come from the SSM public parameter."
  }
}

run "instance_role_matches_the_bootstrap_scope" {
  command = plan

  assert {
    condition     = aws_iam_role.instance.name == "sssc-ec2" && aws_iam_instance_profile.this.name == "sssc-ec2"
    error_message = "The CI apply role may manage only the role and profile named sssc-ec2."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.ssm_core.policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    error_message = "Session Manager access comes from the AWS-managed core policy."
  }
}

run "secrets_and_parameters" {
  command = plan

  assert {
    condition     = toset(keys(aws_secretsmanager_secret.dtrack)) == toset(["admin", "db-app", "secret-key"])
    error_message = "Exactly the admin, db-app and secret-key secrets must exist."
  }

  assert {
    condition     = alltrue([for secret in aws_secretsmanager_secret.dtrack : secret.recovery_window_in_days == 0 && startswith(secret.name, "sssc/dtrack/")])
    error_message = "Secrets must be deleted immediately with the environment, so the next session can recreate them."
  }

  assert {
    condition     = aws_ssm_parameter.bootstrap_status.name == "/sssc/dtrack/bootstrap-status" && nonsensitive(aws_ssm_parameter.bootstrap_status.value) == "pending"
    error_message = "Every environment must start with bootstrap-status = pending, so the barrier can't open early."
  }

  assert {
    condition     = output.ci_api_key_parameter == "/sssc/dtrack/ci-api-key"
    error_message = "The CI API key parameter is written by the instance under /sssc/dtrack."
  }

  assert {
    condition     = aws_cloudwatch_log_group.this.name == "/sssc/dependency-track" && aws_cloudwatch_log_group.this.retention_in_days == 7
    error_message = "Terraform must own the container log group, with 7-day retention."
  }
}
