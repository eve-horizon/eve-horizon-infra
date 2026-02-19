# Eve Horizon Infrastructure - AWS
# Root module supporting both k3s (single EC2) and EKS compute models.

data "aws_caller_identity" "current" {}

locals {
  effective_region               = (var.region != null && trimspace(var.region) != "") ? trimspace(var.region) : var.aws_region
  effective_compute_model        = trimspace(var.compute_model)
  effective_instance_type        = (var.compute_type != null && trimspace(var.compute_type) != "") ? trimspace(var.compute_type) : var.instance_type
  effective_root_volume_size     = var.compute_disk_size_gb != null ? var.compute_disk_size_gb : var.root_volume_size
  effective_db_instance_class    = (var.database_instance_class != null && trimspace(var.database_instance_class) != "") ? trimspace(var.database_instance_class) : var.db_instance_class
  effective_ollama_instance_type = (var.ollama_compute_type != null && trimspace(var.ollama_compute_type) != "") ? trimspace(var.ollama_compute_type) : var.ollama_instance_type
  effective_ollama_volume_size   = var.ollama_disk_size_gb != null ? var.ollama_disk_size_gb : var.ollama_volume_size
  registry_bucket_name           = "${var.name_prefix}-registry-${data.aws_caller_identity.current.account_id}"
}

# -----------------------------------------------------------------------------
# Network Module
# -----------------------------------------------------------------------------
module "network" {
  source = "./modules/network"

  name_prefix   = var.name_prefix
  vpc_cidr      = var.vpc_cidr
  compute_model = local.effective_compute_model
}

# -----------------------------------------------------------------------------
# Security Module
# -----------------------------------------------------------------------------
module "security" {
  source = "./modules/security"

  name_prefix       = var.name_prefix
  vpc_id            = module.network.vpc_id
  allowed_ssh_cidrs = var.allowed_ssh_cidrs
  compute_model     = local.effective_compute_model
}

# -----------------------------------------------------------------------------
# Shared SSH key pair (used by EC2 and Ollama)
# -----------------------------------------------------------------------------
resource "aws_key_pair" "main" {
  key_name   = "${var.name_prefix}-key"
  public_key = var.ssh_public_key

  tags = {
    Name = "${var.name_prefix}-key"
  }
}

# -----------------------------------------------------------------------------
# RDS Module
# -----------------------------------------------------------------------------
module "rds" {
  source = "./modules/rds"

  name_prefix         = var.name_prefix
  subnet_ids          = module.network.private_subnet_ids
  security_group_id   = module.security.rds_security_group_id
  db_name             = var.db_name
  db_username         = var.db_username
  db_password         = var.db_password
  db_instance_class   = local.effective_db_instance_class
  deletion_protection = var.deletion_protection
}

# -----------------------------------------------------------------------------
# EKS Module (EKS mode only)
# -----------------------------------------------------------------------------
module "eks" {
  count  = local.effective_compute_model == "eks" ? 1 : 0
  source = "./modules/eks"

  name_prefix           = var.name_prefix
  cluster_version       = "1.33"
  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  private_subnet_ids    = module.network.private_subnet_ids
  admin_principal_arns  = var.eks_admin_principal_arns
  default_instance_type = var.eks_default_instance_type
  default_min_size      = var.eks_default_min_size
  default_max_size      = var.eks_default_max_size
  default_desired_size  = var.eks_default_desired_size
  agents_instance_types = var.eks_agents_instance_types
  agents_min_size       = var.eks_agents_min_size
  agents_max_size       = var.eks_agents_max_size
  agents_desired_size   = var.eks_agents_desired_size
  apps_instance_types   = var.eks_apps_instance_types
  apps_min_size         = var.eks_apps_min_size
  apps_max_size         = var.eks_apps_max_size
  apps_desired_size     = var.eks_apps_desired_size
}

resource "aws_security_group_rule" "rds_from_compute" {
  type                     = "ingress"
  security_group_id        = module.security.rds_security_group_id
  description              = "PostgreSQL from compute nodes"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = local.effective_compute_model == "eks" ? module.eks[0].node_security_group_id : module.security.ec2_security_group_id
}

# -----------------------------------------------------------------------------
# IAM — k3s Node Role (k3s mode only)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "k3s_node" {
  count = local.effective_compute_model == "k3s" ? 1 : 0
  name  = "${var.name_prefix}-k3s-node-role"

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
  count = local.effective_compute_model == "k3s" ? 1 : 0
  name  = "${var.name_prefix}-k3s-node-profile"
  role  = aws_iam_role.k3s_node[0].name

  tags = { Name = "${var.name_prefix}-k3s-node-profile" }
}

# -----------------------------------------------------------------------------
# EC2 Module (k3s mode only)
# -----------------------------------------------------------------------------
module "ec2" {
  count  = local.effective_compute_model == "k3s" ? 1 : 0
  source = "./modules/ec2"

  name_prefix               = var.name_prefix
  subnet_id                 = module.network.public_subnet_id
  security_group_ids        = [module.security.ec2_security_group_id]
  instance_type             = local.effective_instance_type
  root_volume_size          = local.effective_root_volume_size
  ssh_key_name              = aws_key_pair.main.key_name
  database_url              = "postgresql://${var.db_username}:${var.db_password}@${module.rds.endpoint}:5432/${module.rds.database_name}"
  domain                    = var.domain
  iam_instance_profile_name = aws_iam_instance_profile.k3s_node[0].name
}

# -----------------------------------------------------------------------------
# Registry S3 backend + IRSA (EKS mode only)
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "registry" {
  count  = local.effective_compute_model == "eks" ? 1 : 0
  bucket = local.registry_bucket_name
}

resource "aws_s3_bucket_versioning" "registry" {
  count  = local.effective_compute_model == "eks" ? 1 : 0
  bucket = aws_s3_bucket.registry[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "registry" {
  count  = local.effective_compute_model == "eks" ? 1 : 0
  bucket = aws_s3_bucket.registry[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "registry" {
  count  = local.effective_compute_model == "eks" ? 1 : 0
  bucket = aws_s3_bucket.registry[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role" "registry_irsa" {
  count = local.effective_compute_model == "eks" ? 1 : 0
  name  = "${var.name_prefix}-registry-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks[0].oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${trimprefix(module.eks[0].oidc_provider_url, "https://")}:aud" = "sts.amazonaws.com"
            "${trimprefix(module.eks[0].oidc_provider_url, "https://")}:sub" = "system:serviceaccount:eve:eve-registry"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "registry_irsa" {
  count = local.effective_compute_model == "eks" ? 1 : 0
  name  = "${var.name_prefix}-registry-s3"
  role  = aws_iam_role.registry_irsa[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = [
          aws_s3_bucket.registry[0].arn,
          "${aws_s3_bucket.registry[0].arn}/*",
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Ollama GPU Host Module (optional)
# -----------------------------------------------------------------------------
module "ollama" {
  count  = var.ollama_enabled ? 1 : 0
  source = "./modules/ollama"

  name_prefix               = var.name_prefix
  vpc_id                    = module.network.vpc_id
  subnet_id                 = module.network.public_subnet_ids[0]
  compute_security_group_id = local.effective_compute_model == "eks" ? module.eks[0].node_security_group_id : module.security.ec2_security_group_id
  allowed_ssh_cidrs         = var.allowed_ssh_cidrs
  instance_type             = local.effective_ollama_instance_type
  volume_size               = local.effective_ollama_volume_size
  idle_timeout_minutes      = var.ollama_idle_timeout_minutes
  ssh_key_name              = aws_key_pair.main.key_name
}

# IAM: let k3s node wake/query the Ollama ASG (k3s mode only)
resource "aws_iam_role_policy" "k3s_ollama_wake" {
  count = var.ollama_enabled && local.effective_compute_model == "k3s" ? 1 : 0
  name  = "${var.name_prefix}-k3s-ollama-wake"
  role  = aws_iam_role.k3s_node[0].id

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
# -----------------------------------------------------------------------------
module "dns" {
  source = "./modules/dns"

  domain              = var.domain
  route53_zone_id     = var.route53_zone_id
  compute_model       = local.effective_compute_model
  ec2_public_ip       = local.effective_compute_model == "k3s" ? module.ec2[0].public_ip : null
  ingress_lb_dns_name = var.ingress_lb_dns_name
  ingress_lb_zone_id  = var.ingress_lb_zone_id
}
