# Eve Horizon Infrastructure - AWS Providers

terraform {
  required_version = ">= 1.5.0"

  backend "s3" {
    bucket         = "eh1-terraform-state-767828750268"
    key            = "env/staging/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "eh1-tf-lock"
    encrypt        = true
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
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
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
