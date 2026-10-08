provider "aws" {
  region = var.region

  # Every resource carries these tags, which makes cost per project and the leftover check after a
  # teardown (runbook §6) possible.
  default_tags {
    tags = {
      Project     = "sssc-poc"
      Environment = "poc"
      ManagedBy   = "terraform"
      Repository  = "vkorzavatykh/secure-software-supply-chain-aws"
    }
  }
}
