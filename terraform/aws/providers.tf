# Eve Horizon Infrastructure - AWS Providers

terraform {
  required_version = ">= 1.5.0"

  # Partial backend configuration — the state location is instance-specific,
  # so bucket/key/region/dynamodb_table are supplied at init time rather than
  # committed:
  #
  #   terraform init -backend-config=backend.hcl
  #
  # Bootstrap the bucket + lock table first with `terraform/aws-backend`, then
  # copy backend.hcl.example to backend.hcl and fill in your values.
  backend "s3" {
    encrypt = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = local.effective_region

  default_tags {
    tags = local.cost_tags
  }
}

# us-west-2 is SES's home region for Eve — the SMTP host the API mailer
# points at lives in us-west-2 regardless of where the EKS cluster runs.
# SES configuration sets, the SNS feedback topic, and its subscription must
# all be colocated there.
provider "aws" {
  alias  = "us_west_2"
  region = "us-west-2"

  default_tags {
    tags = local.cost_tags
  }
}

data "aws_eks_cluster_auth" "main" {
  count = local.effective_compute_model == "eks" ? 1 : 0
  name  = module.eks[0].cluster_name
}

provider "kubernetes" {
  host = local.effective_compute_model == "eks" ? module.eks[0].cluster_endpoint : "https://127.0.0.1"
  cluster_ca_certificate = local.effective_compute_model == "eks" ? (
    base64decode(module.eks[0].cluster_ca_certificate)
  ) : null
  token = local.effective_compute_model == "eks" ? data.aws_eks_cluster_auth.main[0].token : null
}
