variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
}

variable "network_id" {
  description = "VPC network ID for private services access"
  type        = string
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
}

variable "db_username" {
  description = "PostgreSQL admin username"
  type        = string
}

variable "db_password" {
  description = "PostgreSQL admin password"
  type        = string
  sensitive   = true
}

variable "tier" {
  description = "Cloud SQL machine tier"
  type        = string
}

variable "deletion_protection" {
  description = "Enable deletion protection"
  type        = bool
}
