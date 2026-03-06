# EKS Module
# Managed control plane, managed node groups, core addons, and IRSA primitives.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  cluster_name = "${var.name_prefix}-cluster"
  admin_principals = length(var.admin_principal_arns) > 0 ? toset(var.admin_principal_arns) : toset([
    data.aws_caller_identity.current.arn,
  ])
}

# -----------------------------------------------------------------------------
# IAM Roles
# -----------------------------------------------------------------------------

resource "aws_iam_role" "cluster" {
  name = "${var.name_prefix}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "eks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "node" {
  name = "${var.name_prefix}-eks-node-role"

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
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------

resource "aws_security_group" "nodes" {
  name        = "${var.name_prefix}-eks-nodes-sg"
  description = "Shared SG for EKS worker nodes"
  vpc_id      = var.vpc_id

  # IMPORTANT: No inline ingress/egress blocks here.
  # Using separate aws_security_group_rule resources below so that
  # Terraform does NOT clobber rules added by the AWS Load Balancer
  # Controller (kubernetes.io/rule/nlb/* rules for NLB NodePort traffic).
  # Inline blocks make Terraform authoritative over ALL rules, causing it
  # to revoke any rule not declared here on every apply.

  tags = {
    Name = "${var.name_prefix}-eks-nodes-sg"
  }

  lifecycle {
    # Ignore ingress/egress changes made by K8s cloud controller
    ignore_changes = [ingress, egress]
  }
}

# --- Node SG rules (separate resources to coexist with K8s-managed rules) ---

resource "aws_security_group_rule" "nodes_self" {
  description       = "Node-to-node traffic"
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.nodes.id
}

resource "aws_security_group_rule" "nodes_nlb_health" {
  description       = "NLB health checks on NodePort range (VPC CIDR)"
  type              = "ingress"
  from_port         = 30000
  to_port           = 32767
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.nodes.id
}

resource "aws_security_group_rule" "nodes_nlb_client" {
  description       = "NLB client traffic on NodePort range (TCP mode preserves source IP)"
  type              = "ingress"
  from_port         = 30000
  to_port           = 32767
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.nodes.id
}

resource "aws_security_group_rule" "nodes_egress" {
  description       = "All outbound"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.nodes.id
}

# -----------------------------------------------------------------------------
# EKS Cluster
# -----------------------------------------------------------------------------

resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  access_config {
    authentication_mode = "API"
  }

  vpc_config {
    subnet_ids              = concat(var.public_subnet_ids, var.private_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = true
    security_group_ids      = [aws_security_group.nodes.id]
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# -----------------------------------------------------------------------------
# IRSA/OIDC
# -----------------------------------------------------------------------------

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}

resource "aws_iam_role" "ebs_csi_irsa" {
  name = "${var.name_prefix}-eks-ebs-csi-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${trimprefix(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://")}:aud" = "sts.amazonaws.com"
            "${trimprefix(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  role       = aws_iam_role.ebs_csi_irsa.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role" "cluster_autoscaler_irsa" {
  name = "${var.name_prefix}-eks-cluster-autoscaler-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${trimprefix(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://")}:aud" = "sts.amazonaws.com"
            "${trimprefix(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://")}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name = "${var.name_prefix}-eks-cluster-autoscaler"
  role = aws_iam_role.cluster_autoscaler_irsa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:DescribeInstanceTypes",
          "eks:DescribeNodegroup",
        ]
        Resource = "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Launch Templates (attach shared node SG)
# -----------------------------------------------------------------------------

resource "aws_launch_template" "default" {
  name_prefix            = "${var.name_prefix}-eks-default-"
  update_default_version = true
  vpc_security_group_ids = [aws_security_group.nodes.id]

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.name_prefix}-eks-default"
    }
  }
}

resource "aws_launch_template" "agents" {
  name_prefix            = "${var.name_prefix}-eks-agents-"
  update_default_version = true
  vpc_security_group_ids = [aws_security_group.nodes.id]

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.name_prefix}-eks-agents"
    }
  }
}

resource "aws_launch_template" "apps" {
  name_prefix            = "${var.name_prefix}-eks-apps-"
  update_default_version = true
  vpc_security_group_ids = [aws_security_group.nodes.id]

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.name_prefix}-eks-apps"
    }
  }
}

# -----------------------------------------------------------------------------
# Managed Node Groups
# -----------------------------------------------------------------------------

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = [var.default_instance_type]
  capacity_type   = "ON_DEMAND"

  launch_template {
    id      = aws_launch_template.default.id
    version = aws_launch_template.default.latest_version
  }

  scaling_config {
    min_size     = var.default_min_size
    max_size     = var.default_max_size
    desired_size = var.default_desired_size
  }

  labels = {
    role = "default"
  }

  tags = {
    Name                                              = "${var.name_prefix}-default"
    "k8s.io/cluster-autoscaler/enabled"               = "true"
    "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
  }

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

resource "aws_eks_node_group" "agents" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "agents"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = coalesce(var.agents_subnet_ids, var.private_subnet_ids)
  instance_types  = var.agents_instance_types
  capacity_type   = "SPOT"

  launch_template {
    id      = aws_launch_template.agents.id
    version = aws_launch_template.agents.latest_version
  }

  scaling_config {
    min_size     = var.agents_min_size
    max_size     = var.agents_max_size
    desired_size = var.agents_desired_size
  }

  labels = {
    role = "agents"
  }

  taint {
    key    = "role"
    value  = "agents"
    effect = "NO_SCHEDULE"
  }

  tags = {
    Name                                              = "${var.name_prefix}-agents"
    "k8s.io/cluster-autoscaler/enabled"               = "true"
    "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
  }

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

resource "aws_eks_node_group" "apps" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "apps"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = var.apps_instance_types
  capacity_type   = "SPOT"

  launch_template {
    id      = aws_launch_template.apps.id
    version = aws_launch_template.apps.latest_version
  }

  scaling_config {
    min_size     = var.apps_min_size
    max_size     = var.apps_max_size
    desired_size = var.apps_desired_size
  }

  labels = {
    role = "apps"
  }

  taint {
    key    = "role"
    value  = "apps"
    effect = "NO_SCHEDULE"
  }

  tags = {
    Name                                              = "${var.name_prefix}-apps"
    "k8s.io/cluster-autoscaler/enabled"               = "true"
    "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
  }

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

# -----------------------------------------------------------------------------
# EKS Addons
# -----------------------------------------------------------------------------

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  depends_on = [aws_eks_node_group.default]
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  depends_on = [aws_eks_node_group.default]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"

  depends_on = [aws_eks_node_group.default]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi_irsa.arn

  depends_on = [
    aws_eks_node_group.default,
    aws_iam_role_policy_attachment.ebs_csi_policy,
  ]
}

# -----------------------------------------------------------------------------
# Cluster Access Entries
# -----------------------------------------------------------------------------

resource "aws_eks_access_entry" "admin" {
  for_each = local.admin_principals

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = local.admin_principals

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
