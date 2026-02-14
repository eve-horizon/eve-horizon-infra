# Eve Horizon Infrastructure - AWS
# Root module for AWS-based Eve Horizon deployment
#
# Provisions a single-node k3s server on EC2 with a managed PostgreSQL
# database, DNS records, and security groups. Suitable for staging,
# production, or any named environment.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# -----------------------------------------------------------------------------
# Network Module
# VPC, subnets, internet gateway, route tables
# -----------------------------------------------------------------------------
module "network" {
  source = "./modules/network"

  name_prefix = var.name_prefix
  vpc_cidr    = var.vpc_cidr
}

# -----------------------------------------------------------------------------
# Security Module
# Security groups, SSH key pair, IAM roles
# -----------------------------------------------------------------------------
module "security" {
  source = "./modules/security"

  name_prefix       = var.name_prefix
  vpc_id            = module.network.vpc_id
  allowed_ssh_cidrs = var.allowed_ssh_cidrs
}

# -----------------------------------------------------------------------------
# RDS Module
# PostgreSQL database instance
# -----------------------------------------------------------------------------
module "rds" {
  source = "./modules/rds"

  name_prefix         = var.name_prefix
  subnet_ids          = module.network.private_subnet_ids
  security_group_id   = module.security.rds_security_group_id
  db_name             = var.db_name
  db_username         = var.db_username
  db_password         = var.db_password
  db_instance_class   = var.db_instance_class
  deletion_protection = var.deletion_protection
}

# -----------------------------------------------------------------------------
# IAM — k3s Node Role
# Allows the k3s node (and its pods) to call AWS APIs.
# Always created (free). Policies are added by optional modules.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "k3s_node" {
  name = "${var.name_prefix}-k3s-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = { Name = "${var.name_prefix}-k3s-node-role" }
}

resource "aws_iam_instance_profile" "k3s_node" {
  name = "${var.name_prefix}-k3s-node-profile"
  role = aws_iam_role.k3s_node.name

  tags = { Name = "${var.name_prefix}-k3s-node-profile" }
}

# -----------------------------------------------------------------------------
# EC2 Module
# Eve Horizon server instance (k3s single-node)
# -----------------------------------------------------------------------------
module "ec2" {
  source = "./modules/ec2"

  name_prefix               = var.name_prefix
  subnet_id                 = module.network.public_subnet_id
  security_group_ids        = [module.security.ec2_security_group_id]
  instance_type             = var.instance_type
  root_volume_size          = var.root_volume_size
  ssh_public_key            = var.ssh_public_key
  database_url              = "postgresql://${var.db_username}:${var.db_password}@${module.rds.endpoint}:5432/${module.rds.database_name}"
  domain                    = var.domain
  iam_instance_profile_name = aws_iam_instance_profile.k3s_node.name
}

# -----------------------------------------------------------------------------
# Ollama GPU Host Module (optional)
# On-demand spot GPU instance running Ollama
# -----------------------------------------------------------------------------
module "ollama" {
  count  = var.ollama_enabled ? 1 : 0
  source = "./modules/ollama"

  name_prefix           = var.name_prefix
  vpc_id                = module.network.vpc_id
  subnet_id             = module.network.public_subnet_id
  k3s_security_group_id = module.security.ec2_security_group_id
  allowed_ssh_cidrs     = var.allowed_ssh_cidrs
  instance_type         = var.ollama_instance_type
  volume_size           = var.ollama_volume_size
  idle_timeout_minutes  = var.ollama_idle_timeout_minutes
  ssh_key_name          = module.ec2.key_pair_name
}

# IAM: let k3s node wake/query the Ollama ASG
resource "aws_iam_role_policy" "k3s_ollama_wake" {
  count = var.ollama_enabled ? 1 : 0
  name  = "${var.name_prefix}-k3s-ollama-wake"
  role  = aws_iam_role.k3s_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "autoscaling:UpdateAutoScalingGroup"
        Resource = module.ollama[0].asg_arn
      },
      {
        Effect   = "Allow"
        Action   = "autoscaling:DescribeAutoScalingGroups"
        Resource = "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# DNS Module
# Route53 records for the Eve Horizon domain
# -----------------------------------------------------------------------------
module "dns" {
  source = "./modules/dns"

  domain          = var.domain
  route53_zone_id = var.route53_zone_id
  ec2_public_ip   = module.ec2.public_ip
}
