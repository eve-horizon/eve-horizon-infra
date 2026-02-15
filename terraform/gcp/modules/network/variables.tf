variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
}

variable "subnet_cidr" {
  description = "Primary subnet CIDR range"
  type        = string
}

variable "pods_cidr" {
  description = "Secondary CIDR range for GKE pods"
  type        = string
}

variable "services_cidr" {
  description = "Secondary CIDR range for GKE services"
  type        = string
}
