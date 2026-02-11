# Eve Horizon Infrastructure - Input Variables

# -----------------------------------------------------------------------------
# Project Naming
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Project name used for resource tagging"
  type        = string
  default     = "eve-horizon"
}

variable "environment" {
  description = "Environment name (e.g., staging, production)"
  type        = string
  default     = "staging"
}

variable "name_prefix" {
  description = "Prefix for all AWS resource names (e.g., eve-staging, eve-prod, myorg-eve)"
  type        = string
  # No default - must be explicitly set to avoid naming collisions
}

# -----------------------------------------------------------------------------
# AWS Configuration
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-west-2"
}

# -----------------------------------------------------------------------------
# Network Configuration
# -----------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "allowed_ssh_cidrs" {
  description = "List of CIDR blocks allowed to SSH to the EC2 instance and access the K8s API"
  type        = list(string)
  # No default - must be explicitly set for security
}

# -----------------------------------------------------------------------------
# EC2 Configuration
# -----------------------------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type for the Eve Horizon server"
  type        = string
  default     = "m6i.xlarge"
}

variable "root_volume_size" {
  description = "Size in GB of the root EBS volume"
  type        = number
  default     = 50
}

variable "ssh_public_key" {
  description = "SSH public key for EC2 access (contents of your .pub file)"
  type        = string
  sensitive   = true
}

# -----------------------------------------------------------------------------
# DNS Configuration
# -----------------------------------------------------------------------------

variable "domain" {
  description = "Domain name for Eve Horizon (e.g., eve.example.com). Must be under the Route53 zone."
  type        = string
  # No default - must be explicitly set
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for your domain"
  type        = string
  # No default - must be explicitly set
}

# -----------------------------------------------------------------------------
# Database Configuration
# -----------------------------------------------------------------------------

variable "db_name" {
  description = "Name of the PostgreSQL database"
  type        = string
  default     = "eve"
}

variable "db_username" {
  description = "Master username for the PostgreSQL database"
  type        = string
  default     = "eve"
}

variable "db_password" {
  description = "Master password for the PostgreSQL database"
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class for PostgreSQL"
  type        = string
  default     = "db.t3.micro"
}

variable "deletion_protection" {
  description = "Enable deletion protection on the RDS instance (recommended for production)"
  type        = bool
  default     = false
}
