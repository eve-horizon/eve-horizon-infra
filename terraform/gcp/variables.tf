# Eve Horizon Infrastructure — GCP Input Variables

# -----------------------------------------------------------------------------
# GCP Identity
# -----------------------------------------------------------------------------

variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region (legacy alias; prefer region)"
  type        = string
  default     = "us-central1"
}

variable "region" {
  description = "Cloud region (canonical). Overrides gcp_region when set."
  type        = string
  default     = null
}

variable "gcp_zone" {
  description = "GCP zone for zonal GKE cluster (e.g. us-central1-a)"
  type        = string
  default     = "us-central1-a"
}

# -----------------------------------------------------------------------------
# Project Naming
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Project name for resource labeling"
  type        = string
  default     = "eve-horizon"
}

variable "environment" {
  description = "Environment name (staging, production)"
  type        = string
  default     = "staging"
}

variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  # No default — must be explicitly set to avoid naming collisions
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

variable "subnet_cidr" {
  description = "Primary subnet CIDR range"
  type        = string
  default     = "10.0.0.0/24"
}

variable "pods_cidr" {
  description = "Secondary CIDR range for GKE pods"
  type        = string
  default     = "10.1.0.0/16"
}

variable "services_cidr" {
  description = "Secondary CIDR range for GKE services"
  type        = string
  default     = "10.2.0.0/20"
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed SSH access to nodes"
  type        = list(string)
  # No default — must be explicitly set for security
}

variable "allowed_api_cidrs" {
  description = "CIDR blocks allowed to access the GKE API server"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# -----------------------------------------------------------------------------
# GKE — Default Pool (core services)
# -----------------------------------------------------------------------------

variable "default_node_machine_type" {
  description = "Machine type for the default (system) node pool (legacy alias; prefer compute_type)"
  type        = string
  default     = "e2-standard-2" # 2 vCPU, 8 GB — runs core services
}

variable "compute_type" {
  description = "Compute class/type for primary app/control nodes (canonical). Overrides default_node_machine_type when set."
  type        = string
  default     = null
}

variable "default_node_count" {
  description = "Initial node count for the default pool"
  type        = number
  default     = 1
}

variable "default_node_min" {
  description = "Minimum nodes in default pool (autoscaler)"
  type        = number
  default     = 1
}

variable "default_node_max" {
  description = "Maximum nodes in default pool (autoscaler)"
  type        = number
  default     = 2
}

# -----------------------------------------------------------------------------
# GKE — Agent Pool (spot)
# -----------------------------------------------------------------------------

variable "agent_node_machine_type" {
  description = "Machine type for the agent-runtime spot node pool"
  type        = string
  default     = "e2-standard-2" # 2 vCPU, 8 GB — runs agent workloads
}

variable "agent_node_min" {
  description = "Minimum nodes in agent spot pool (can be 0)"
  type        = number
  default     = 0
}

variable "agent_node_max" {
  description = "Maximum nodes in agent spot pool"
  type        = number
  default     = 2
}

# -----------------------------------------------------------------------------
# GKE — Apps Pool (spot)
# -----------------------------------------------------------------------------

variable "apps_node_machine_type" {
  description = "Machine type for the user app spot node pool"
  type        = string
  default     = "e2-standard-2" # 2 vCPU, 8 GB — runs user-deployed apps
}

variable "apps_node_min" {
  description = "Minimum nodes in apps spot pool (can be 0)"
  type        = number
  default     = 0
}

variable "apps_node_max" {
  description = "Maximum nodes in apps spot pool"
  type        = number
  default     = 2
}

# -----------------------------------------------------------------------------
# GKE — Common
# -----------------------------------------------------------------------------

variable "boot_disk_size" {
  description = "Boot disk size in GB for GKE nodes (legacy alias; prefer compute_disk_size_gb)"
  type        = number
  default     = 50
}

variable "compute_disk_size_gb" {
  description = "Primary node boot disk size in GB (canonical). Overrides boot_disk_size when set."
  type        = number
  default     = null
}

variable "ssh_public_key" {
  description = "SSH public key for node access (optional, for debugging)"
  type        = string
  sensitive   = true
  default     = ""
}

# -----------------------------------------------------------------------------
# Domain
# -----------------------------------------------------------------------------

variable "domain" {
  description = "Eve Horizon domain name"
  type        = string
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone name"
  type        = string
}

# -----------------------------------------------------------------------------
# Database
# -----------------------------------------------------------------------------

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "eve"
}

variable "db_username" {
  description = "PostgreSQL admin username"
  type        = string
  default     = "eve"
}

variable "db_password" {
  description = "PostgreSQL admin password"
  type        = string
  sensitive   = true
}

variable "db_tier" {
  description = "Cloud SQL machine tier (legacy alias; prefer database_instance_class)"
  type        = string
  default     = "db-f1-micro"
}

variable "database_instance_class" {
  description = "Managed database instance class/tier (canonical). Overrides db_tier when set."
  type        = string
  default     = null
}

variable "deletion_protection" {
  description = "Enable deletion protection on Cloud SQL"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Ollama GPU (optional)
# -----------------------------------------------------------------------------

variable "ollama_enabled" {
  description = "Enable on-demand Ollama GPU host"
  type        = bool
  default     = false
}

variable "ollama_machine_type" {
  description = "GCE machine type for Ollama GPU host (legacy alias; prefer ollama_compute_type)"
  type        = string
  default     = "g2-standard-4"
}

variable "ollama_gpu_type" {
  description = "GPU accelerator type"
  type        = string
  default     = "nvidia-l4"
}

variable "ollama_disk_size" {
  description = "Persistent disk size in GB for model storage (legacy alias; prefer ollama_disk_size_gb)"
  type        = number
  default     = 100
}

variable "ollama_compute_type" {
  description = "Compute class/type for the Ollama host (canonical). Overrides ollama_machine_type when set."
  type        = string
  default     = null
}

variable "ollama_disk_size_gb" {
  description = "Disk size in GB for Ollama model storage (canonical). Overrides ollama_disk_size when set."
  type        = number
  default     = null
}

variable "ollama_idle_timeout_minutes" {
  description = "Minutes of inactivity before GPU auto-shuts down"
  type        = number
  default     = 30
}
