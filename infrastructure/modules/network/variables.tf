variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = "sssc"
}

variable "vpc_cidr" {
  description = "VPC address range. Each tier gets one /24 per Availability Zone at a fixed offset (architecture §3)."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 16
    error_message = "Use a valid IPv4 CIDR block of /16 or larger."
  }
}

variable "availability_zones" {
  description = "Two Availability Zones. The ALB and the RDS subnet group both need subnets in at least two."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) == 2
    error_message = "Exactly two Availability Zones are expected."
  }
}

variable "allowed_ingress_cidrs" {
  description = "IPv4 ranges allowed to reach the load balancer on 80 and 443."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0 && alltrue([for cidr in var.allowed_ingress_cidrs : can(cidrhost(cidr, 0))])
    error_message = "Provide at least one valid IPv4 CIDR block."
  }
}

variable "app_ports" {
  description = "Host ports on the instance that the load balancer forwards to: the Dependency-Track UI and API."
  type        = map(number)
  default = {
    ui  = 8080
    api = 8081
  }
}

variable "db_port" {
  description = "PostgreSQL port."
  type        = number
  default     = 5432
}
