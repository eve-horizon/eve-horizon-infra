# EKS Module - Input Variables

variable "name_prefix" {
  description = "Prefix for AWS resource names"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for EKS control plane"
  type        = string
  default     = "1.33"
}

variable "vpc_id" {
  description = "VPC ID for the cluster"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block (for NLB NodePort ingress rules)"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for control plane/LB placement"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for worker nodes"
  type        = list(string)
}

variable "admin_principal_arns" {
  description = "IAM principal ARNs granted EKS cluster admin access via access entries"
  type        = list(string)
  default     = []
}

variable "default_instance_type" {
  description = "Instance type for default (always-on) node group"
  type        = string
  default     = "t3.large"
}

variable "default_min_size" {
  description = "Minimum size for default node group"
  type        = number
  default     = 1
}

variable "default_max_size" {
  description = "Maximum size for default node group"
  type        = number
  default     = 2
}

variable "default_desired_size" {
  description = "Desired size for default node group"
  type        = number
  default     = 1
}

variable "agents_instance_types" {
  description = "Instance types for agents spot node group"
  type        = list(string)
  default     = ["m6i.xlarge", "m5.xlarge"]
}

variable "agents_min_size" {
  description = "Minimum size for agents node group"
  type        = number
  default     = 0
}

variable "agents_max_size" {
  description = "Maximum size for agents node group"
  type        = number
  default     = 3
}

variable "agents_desired_size" {
  description = "Desired size for agents node group"
  type        = number
  default     = 0
}

variable "apps_instance_types" {
  description = "Instance types for apps spot node group"
  type        = list(string)
  default     = ["t3.large", "t3.medium"]
}

variable "apps_min_size" {
  description = "Minimum size for apps node group"
  type        = number
  default     = 0
}

variable "apps_max_size" {
  description = "Maximum size for apps node group"
  type        = number
  default     = 5
}

variable "apps_desired_size" {
  description = "Desired size for apps node group"
  type        = number
  default     = 0
}
