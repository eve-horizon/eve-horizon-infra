variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "network_name" {
  description = "VPC network name"
  type        = string
}

variable "subnet_name" {
  description = "Subnet name"
  type        = string
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed SSH access"
  type        = list(string)
}

variable "gke_node_cidr" {
  description = "CIDR range for GKE node IPs (firewall source for Ollama API)"
  type        = string
}

variable "machine_type" {
  description = "GCE machine type for Ollama GPU host"
  type        = string
}

variable "gpu_type" {
  description = "GPU accelerator type"
  type        = string
}

variable "disk_size" {
  description = "Persistent disk size in GB for model storage"
  type        = number
}

variable "idle_timeout_minutes" {
  description = "Minutes of inactivity before GPU auto-shuts down"
  type        = number
}

variable "ssh_public_key" {
  description = "SSH public key for instance access"
  type        = string
  sensitive   = true
  default     = ""
}
