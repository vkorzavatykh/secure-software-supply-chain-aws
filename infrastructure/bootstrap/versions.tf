terraform {
  # 1.10+ for S3-native state locking (use_lockfile) in the environments that use this bucket.
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }

  # State stays local on purpose (see ../README.md#state): this stack creates the state bucket, and it is
  # destroyed last, after that bucket has been emptied.
}
