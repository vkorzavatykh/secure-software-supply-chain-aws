terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.4"
    }
  }

  # State in the bootstrap bucket with S3-native locking; no DynamoDB table (ADR-008). The bucket name
  # contains the account ID, so it is passed at init time instead of being committed:
  #   terraform init -backend-config="bucket=<state bucket>"
  backend "s3" {
    key          = "poc/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
