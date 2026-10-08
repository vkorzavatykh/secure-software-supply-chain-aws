# RDS PostgreSQL for Dependency-Track (architecture §7, ADR-003). Persistent state lives here, so the
# instance can be replaced at will. The master password is created and stored by RDS in Secrets Manager
# and never appears in Terraform code, variables, plans or state (ADR-010). Dependency-Track connects as
# its own least-privilege role, which the instance bootstrap creates (ADR-022).

locals {
  major_version = split(".", var.engine_version)[0]
}

resource "aws_db_subnet_group" "this" {
  name        = var.identifier
  description = "Private data subnets without an internet route"
  subnet_ids  = var.subnet_ids
}

resource "aws_db_parameter_group" "this" {
  name        = "${var.identifier}-pg${local.major_version}"
  family      = "postgres${local.major_version}"
  description = "Dependency-Track: TLS required for every connection"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier = var.identifier

  engine                     = "postgres"
  engine_version             = var.engine_version
  auto_minor_version_upgrade = true
  instance_class             = var.instance_class
  parameter_group_name       = aws_db_parameter_group.this.name

  # No database name: the bootstrap creates database "dtrack", owned by role "dtrack" (ADR-022).
  username                    = var.master_username
  manage_master_user_password = true
  port                        = var.port

  allocated_storage     = var.allocated_storage
  max_allocated_storage = 0
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period  = var.backup_retention_period
  copy_tags_to_snapshot    = true
  delete_automated_backups = true

  # The environment must be destroyable in one command.
  deletion_protection       = false
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.identifier}-final"
  apply_immediately         = true
}
