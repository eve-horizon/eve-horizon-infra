# EKS Egress Pool Module — Input Variables
#
# A managed EKS node group dedicated to apps that opt into stable egress
# (manifest: `x-eve.networking.egress: stable`). Pods scheduled here run with
# `hostNetwork: true` so their UDP source IP/port mappings are translated 1:1
# by the Internet Gateway path attached to the node's public IPv4. Replaces
# the v1 Tailscale exit-node design.
#
# See docs/plans/app-stable-egress-v2-plan.md (eve-horizon-2).

variable "name_prefix" {
  description = "Prefix for AWS resource names (matches root name_prefix)."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name to attach the node group to (typically `module.eks[0].cluster_name`)."
  type        = string
}

variable "node_role_arn" {
  description = "IAM role ARN for the node group instances (typically `module.eks[0].node_role_arn`)."
  type        = string
}

variable "node_security_group_id" {
  description = "Shared cluster node security group (typically `module.eks[0].node_security_group_id`). Attached to instances via the launch template."
  type        = string
}

variable "subnet_ids" {
  description = "Public subnet IDs the egress pool may schedule into. Phase 1 ships a single eu-west-1b subnet; Phase 2 spreads across ≥2 AZs."
  type        = list(string)
}

variable "instance_types" {
  description = "EC2 instance types for the egress node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "capacity_type" {
  description = "ON_DEMAND or SPOT. POC uses ON_DEMAND so pvscam isn't subject to spot interruption mid-camera-poll."
  type        = string
  default     = "ON_DEMAND"
}

variable "min_size" {
  description = "Minimum size for the egress node group."
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Maximum size for the egress node group."
  type        = number
  default     = 1
}

variable "desired_size" {
  description = "Desired size for the egress node group."
  type        = number
  default     = 1
}

variable "node_disk_size" {
  description = "Root EBS volume size (GiB) for nodes."
  type        = number
  default     = 20
}

variable "resource_tags" {
  description = "Common tags applied to egress-pool cost-bearing resources."
  type        = map(string)
  default     = {}
}

variable "node_label_key" {
  description = "Kubernetes label key applied to nodes. The deployer's `nodeSelector` matches this key/value pair."
  type        = string
  default     = "eve.io/egress-pool"
}

variable "node_label_value" {
  description = "Kubernetes label value applied to nodes."
  type        = string
  default     = "stable"
}

variable "node_taint_key" {
  description = "Kubernetes taint key applied to nodes. Apps without the matching toleration won't schedule here, keeping the node dedicated to opted-in services."
  type        = string
  default     = "eve.io/egress-pool"
}

variable "node_taint_value" {
  description = "Kubernetes taint value."
  type        = string
  default     = "stable"
}

variable "node_taint_effect" {
  description = "Taint effect, in Terraform's EKS API form. `NO_SCHEDULE` renders as Kubernetes `NoSchedule`."
  type        = string
  default     = "NO_SCHEDULE"
}
