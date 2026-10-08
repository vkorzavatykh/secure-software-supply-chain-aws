# Offline tests with a mocked AWS provider for the database properties in architecture §7.

mock_provider "aws" {}

variables {
  subnet_ids        = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
  security_group_id = "sg-0123456789abcdef0"
}

run "database_is_private_encrypted_and_tls_only" {
  command = plan

  assert {
    condition     = aws_db_instance.this.publicly_accessible == false
    error_message = "The database must not be publicly accessible."
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted && aws_db_instance.this.storage_type == "gp3"
    error_message = "Storage must be encrypted gp3."
  }

  assert {
    condition     = one([for parameter in aws_db_parameter_group.this.parameter : parameter.value if parameter.name == "rds.force_ssl"]) == "1"
    error_message = "The parameter group must force TLS."
  }

  assert {
    condition     = aws_db_parameter_group.this.family == "postgres17"
    error_message = "The parameter group family must follow the engine's major version."
  }
}

run "password_is_managed_by_rds" {
  command = plan

  assert {
    condition     = aws_db_instance.this.manage_master_user_password && aws_db_instance.this.password == null
    error_message = "RDS must manage the master password; Terraform must never see it (ADR-010)."
  }
}

run "environment_is_destroyable_in_one_command" {
  command = plan

  assert {
    condition     = !aws_db_instance.this.deletion_protection && aws_db_instance.this.skip_final_snapshot && aws_db_instance.this.delete_automated_backups
    error_message = "By default, destroy must leave no instance, snapshot or backup behind."
  }
}

run "final_snapshot_can_be_kept" {
  command = plan

  variables {
    skip_final_snapshot = false
  }

  assert {
    condition     = aws_db_instance.this.final_snapshot_identifier == "sssc-dtrack-final"
    error_message = "When a final snapshot is kept, it gets a fixed, predictable name."
  }
}

run "rejects_a_single_subnet" {
  command = plan

  variables {
    subnet_ids = ["subnet-0aaaaaaaaaaaaaaaa"]
  }

  expect_failures = [var.subnet_ids]
}
