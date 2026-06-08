# RDS Module - Input Variables

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the DB subnet group"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group ID for the RDS instance"
  type        = string
}

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
  description = "Password for the PostgreSQL database"
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "deletion_protection" {
  description = "Enable deletion protection on the RDS instance"
  type        = bool
  default     = false
}

variable "enabled_preload_extensions" {
  description = "PostgreSQL extensions that require shared_preload_libraries. Currently supports pg_cron."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for extension in var.enabled_preload_extensions : contains(["pg_cron"], extension)
    ])
    error_message = "enabled_preload_extensions currently supports only pg_cron."
  }
}
