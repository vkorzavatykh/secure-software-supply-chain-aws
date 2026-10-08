variable "name_prefix" {
  description = "Prefix for resource names. The instance role is <prefix>-ec2; the bootstrap stack scopes the apply role's IAM rights to that exact name."
  type        = string
  default     = "sssc"
}

variable "subnet_id" {
  description = "Private app subnet for the instance (its route to the NAT Gateway must already exist)."
  type        = string
}

variable "security_group_id" {
  description = "Security Group of the Dependency-Track instance."
  type        = string
}

variable "instance_type" {
  description = "Instance type. The Dependency-Track v4 apiserver needs about 4.5 GiB of RAM."
  type        = string
  default     = "t3.large"
}

variable "root_volume_size" {
  description = "Root volume size in GiB (gp3, encrypted): container images and the vulnerability mirror cache."
  type        = number
  default     = 30
}

variable "ami_ssm_parameter" {
  description = "Public SSM parameter that resolves to the latest Amazon Linux 2023 AMI, so no AMI ID is hard-coded."
  type        = string
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

variable "user_data_base64" {
  description = "Rendered, gzip-compressed cloud-init configuration. Any change replaces the instance (ADR-009)."
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch log group for container logs. Terraform owns it, so nothing is left behind on destroy."
  type        = string
  default     = "/sssc/dependency-track"
}

variable "log_retention_days" {
  description = "Retention of container logs in days."
  type        = number
  default     = 7
}

variable "db_master_secret_arn" {
  description = "RDS-managed master secret. The instance reads it only during bootstrap (ADR-022)."
  type        = string
}

variable "dtrack_secret_prefix" {
  description = "Name prefix of the Secrets Manager secrets the instance writes (admin, db-app, secret-key)."
  type        = string
  default     = "sssc/dtrack"
}

variable "dtrack_parameter_path" {
  description = "SSM Parameter Store path of the Dependency-Track parameters (nvd-api-key, ci-api-key, bootstrap-status)."
  type        = string
  default     = "/sssc/dtrack"
}
