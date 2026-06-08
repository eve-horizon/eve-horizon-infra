# EKS Egress Pool Module
#
# Provisions a managed EKS node group in public subnets so pods that opt into
# stable egress (manifest: `x-eve.networking.egress: stable`) can run with
# `hostNetwork: true` and have their traffic exit via the node's own public
# IPv4 / Internet Gateway path. The 1:1 IGW translation preserves the same
# UDP source port across destinations — what STUN-discovered NAT hole-punching
# expects.
#
# Phase 1 ships min=max=desired=1 in a single AZ. Phase 2 (separate plan):
# multi-AZ, EIP pool, conntrack tuning. See docs/plans/app-stable-egress-v2-plan.md.

# -----------------------------------------------------------------------------
# Launch template
# -----------------------------------------------------------------------------
# `network_interfaces.associate_public_ip_address = true` is what gets the
# node a public IPv4 — required so its egress doesn't traverse the cluster
# NAT Gateway, which is the whole point of this node group.
#
# We attach the shared node SG via `network_interfaces.security_groups` rather
# than the top-level `vpc_security_group_ids` because mixing the two with a
# `network_interfaces` block can be rejected by AWS.
resource "aws_launch_template" "this" {
  name_prefix            = "${var.name_prefix}-eks-egress-"
  update_default_version = true

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = var.node_disk_size
      volume_type = "gp3"
    }
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [var.node_security_group_id]
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.resource_tags, {
      Name      = "${var.name_prefix}-eks-egress"
      Component = "eks-egress-node"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.resource_tags, {
      Name      = "${var.name_prefix}-eks-egress-root"
      Component = "eks-egress-node"
    })
  }
}

# -----------------------------------------------------------------------------
# Managed node group
# -----------------------------------------------------------------------------
resource "aws_eks_node_group" "this" {
  cluster_name    = var.cluster_name
  node_group_name = "egress"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.instance_types
  capacity_type   = var.capacity_type

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }

  scaling_config {
    min_size     = var.min_size
    max_size     = var.max_size
    desired_size = var.desired_size
  }

  labels = {
    (var.node_label_key) = var.node_label_value
  }

  taint {
    key    = var.node_taint_key
    value  = var.node_taint_value
    effect = var.node_taint_effect
  }

  tags = merge(var.resource_tags, {
    Name                                            = "${var.name_prefix}-egress"
    Component                                       = "eks-egress-node-group"
    "k8s.io/cluster-autoscaler/enabled"             = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
  })

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}
