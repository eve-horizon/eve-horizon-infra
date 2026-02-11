# EC2 Module - Input Variables

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "subnet_id" {
  description = "ID of the subnet for the EC2 instance"
  type        = string
}

variable "security_group_ids" {
  description = "List of security group IDs for the EC2 instance"
  type        = list(string)
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "m6i.xlarge"
}

variable "root_volume_size" {
  description = "Size in GB of the root EBS volume"
  type        = number
  default     = 50
}

variable "ssh_public_key" {
  description = "SSH public key for EC2 access"
  type        = string
  sensitive   = true
}

variable "database_url" {
  description = "Database connection URL for Eve Horizon"
  type        = string
  sensitive   = true
}

variable "domain" {
  description = "Domain name for Eve Horizon"
  type        = string
}
