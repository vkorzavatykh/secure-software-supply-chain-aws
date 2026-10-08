variable "identifier" {
  description = "RDS instance identifier; also the name of its subnet group."
  type        = string
  default     = "sssc-dtrack"
}

variable "subnet_ids" {
  description = "Private data subnets, in at least two Availability Zones."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "An RDS subnet group needs subnets in at least two Availability Zones."
  }
}

variable "security_group_id" {
  description = "Security Group that admits PostgreSQL from the Dependency-Track instance only."
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL version. A major version only (for example \"17\") lets RDS apply minor upgrades."
  type        = string
  default     = "17"
}

variable "instance_class" {
  description = "Instance class. Move to db.t4g.small if the first vulnerability mirror is too slow."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Storage in GiB (gp3, encrypted, no autoscaling)."
  type        = number
  default     = 20
}

variable "master_username" {
  description = "Master user. Used only by the instance bootstrap to create the application role (ADR-022)."
  type        = string
  default     = "sssc_admin"
}

variable "port" {
  description = "PostgreSQL port."
  type        = number
  default     = 5432
}

variable "backup_retention_period" {
  description = "Days of automated backups (1-7 for this proof of concept)."
  type        = number
  default     = 1

  validation {
    condition     = var.backup_retention_period >= 1 && var.backup_retention_period <= 7
    error_message = "Keep between 1 and 7 days: enough to show restore, without the cost."
  }
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. Snapshots outlive the environment and cost money (runbook §6)."
  type        = bool
  default     = true
}
