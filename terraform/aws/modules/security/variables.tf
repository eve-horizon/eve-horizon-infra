# Security Module - Input Variables

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC"
  type        = string
}

variable "allowed_ssh_cidrs" {
  description = "List of CIDR blocks allowed to SSH"
  type        = list(string)
}

variable "compute_model" {
  description = "Compute model: k3s (single EC2) or eks (managed cluster)"
  type        = string
  validation {
    condition     = contains(["k3s", "eks"], var.compute_model)
    error_message = "compute_model must be 'k3s' or 'eks'"
  }
}
