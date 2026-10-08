variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = "sssc"
}

variable "vpc_id" {
  description = "VPC of the target groups."
  type        = string
}

variable "subnet_ids" {
  description = "Public subnets for the load balancer, in at least two Availability Zones."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security Group of the load balancer."
  type        = string
}

variable "certificate_arn" {
  description = "ACM certificate for domain_name, created and validated by the bootstrap stack."
  type        = string
}

variable "zone_id" {
  description = "Route 53 zone of domain_name, created by the bootstrap stack."
  type        = string
}

variable "domain_name" {
  description = "Public hostname; the alias record sits at the zone apex."
  type        = string
}

variable "target_instance_id" {
  description = "EC2 instance that runs Dependency-Track."
  type        = string
}

variable "app_ports" {
  description = "Host ports of the Dependency-Track UI and API on the instance."
  type        = map(number)
  default = {
    ui  = 8080
    api = 8081
  }
}

variable "health_check_paths" {
  description = "Health check path per target group. Check them against the pinned Dependency-Track version."
  type        = map(string)
  default = {
    ui  = "/"
    api = "/api/version"
  }
}

variable "dtrack_public" {
  description = "Startup barrier (ADR-020). false: every HTTPS request gets a fixed 503 and nothing is forwarded. Set to true only after bootstrap reports done."
  type        = bool
  default     = false
}

variable "ssl_policy" {
  description = "TLS security policy of the HTTPS listener."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}
