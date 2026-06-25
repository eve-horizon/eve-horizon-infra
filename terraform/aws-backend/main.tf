# Bootstrap root for Terraform remote state backend.
# Uses local state intentionally — it only manages the S3 bucket and DynamoDB
# lock table, not the infrastructure itself.
#
# The bucket and lock-table names are derived from `name_prefix` and the
# current AWS account ID, matching the naming convention used by the main
# root module (see terraform/aws/main.tf). After applying this, feed the
# resulting names into the main module's backend via backend.hcl.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "local" {}
}

variable "name_prefix" {
  description = "Prefix for state bucket / lock table names (match the main module's name_prefix, e.g. eve-demo)."
  type        = string
}

variable "region" {
  description = "AWS region for the state bucket and lock table."
  type        = string
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "tf_state" {
  bucket = "${var.name_prefix}-terraform-state-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_lock" {
  name         = "${var.name_prefix}-tf-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

output "state_bucket" {
  description = "Name of the S3 bucket holding Terraform state. Use in backend.hcl."
  value       = aws_s3_bucket.tf_state.id
}

output "lock_table" {
  description = "Name of the DynamoDB lock table. Use in backend.hcl."
  value       = aws_dynamodb_table.tf_lock.name
}
