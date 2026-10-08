provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "sssc-poc"
      Environment = "bootstrap"
      ManagedBy   = "terraform"
      Repository  = var.github_repository
    }
  }
}
