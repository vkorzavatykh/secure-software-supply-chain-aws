variable "region" {
  description = "AWS region for the state bucket and every regional resource."
  type        = string
  default     = "eu-central-1"
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose workflows may assume the CI roles."
  type        = string
  default     = "vkorzavatykh/secure-software-supply-chain-aws"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Use the form owner/name."
  }
}

variable "github_environment" {
  description = "GitHub environment (with a required reviewer) whose jobs may assume the apply role."
  type        = string
  default     = "poc"
}

variable "state_bucket_force_destroy" {
  description = "Allow destroying the state bucket while it still holds objects. Set to true only for the final teardown."
  type        = bool
  default     = false
}
