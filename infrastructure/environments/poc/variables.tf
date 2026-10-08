variable "region" {
  description = "AWS region. Must match the backend region in versions.tf."
  type        = string
  default     = "eu-central-1"
}

variable "availability_zones" {
  description = "The two Availability Zones of the VPC; the instance and the NAT Gateway use the first."
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b"]
}

variable "dtrack_domain" {
  description = "Public hostname of Dependency-Track. Its zone and certificate come from the bootstrap stack."
  type        = string
  default     = "dtrack.frontward-solutions.com"
}

variable "allowed_ingress_cidrs" {
  description = "IPv4 ranges allowed to reach the load balancer. Narrow to your own IP for extra safety."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "dtrack_public" {
  description = "Startup barrier (ADR-020). Keep false until /sssc/dtrack/bootstrap-status reads done; the infrastructure workflow sets it."
  type        = bool
  default     = false
}

variable "instance_type" {
  description = "Instance type of the Dependency-Track host (x86_64; the AMI parameter and Compose binary assume it)."
  type        = string
  default     = "t3.medium"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "alarm_email" {
  description = "Email address subscribed to the alarm topic. Empty means no subscription. Passed from a GitHub secret in CI."
  type        = string
  default     = ""
  sensitive   = true
}
