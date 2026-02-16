# Ollama GPU Host Module - Input Variables

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC"
  type        = string
}

variable "subnet_id" {
  description = "ID of the public subnet for the Ollama instance"
  type        = string
}

variable "compute_security_group_id" {
  description = "Security group ID of compute nodes allowed to reach Ollama on 11434"
  type        = string
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH to the Ollama instance"
  type        = list(string)
}

variable "instance_type" {
  description = "EC2 instance type (must have NVIDIA GPU)"
  type        = string
  default     = "g5.xlarge"
}

variable "volume_size" {
  description = "EBS volume size in GB for Ollama model storage"
  type        = number
  default     = 100
}

variable "ssh_key_name" {
  description = "Name of the SSH key pair for instance access"
  type        = string
}

variable "idle_timeout_minutes" {
  description = "Minutes of inactivity before the instance auto-shuts down"
  type        = number
  default     = 30
}
