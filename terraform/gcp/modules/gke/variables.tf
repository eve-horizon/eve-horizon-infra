variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
}

variable "zone" {
  description = "GCP zone for the zonal GKE cluster"
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

variable "pods_range_name" {
  description = "Name of the secondary IP range for pods"
  type        = string
}

variable "services_range_name" {
  description = "Name of the secondary IP range for services"
  type        = string
}

# --- Default pool ---

variable "default_node_machine_type" {
  description = "Machine type for the default (system) node pool"
  type        = string
}

variable "default_node_count" {
  description = "Initial node count for the default pool"
  type        = number
}

variable "default_node_min" {
  description = "Minimum nodes in default pool (autoscaler)"
  type        = number
}

variable "default_node_max" {
  description = "Maximum nodes in default pool (autoscaler)"
  type        = number
}

# --- Agent pool ---

variable "agent_node_machine_type" {
  description = "Machine type for the agent-runtime spot node pool"
  type        = string
}

variable "agent_node_min" {
  description = "Minimum nodes in agent spot pool"
  type        = number
}

variable "agent_node_max" {
  description = "Maximum nodes in agent spot pool"
  type        = number
}

# --- Apps pool ---

variable "apps_node_machine_type" {
  description = "Machine type for the user app spot node pool"
  type        = string
}

variable "apps_node_min" {
  description = "Minimum nodes in apps spot pool"
  type        = number
}

variable "apps_node_max" {
  description = "Maximum nodes in apps spot pool"
  type        = number
}

# --- Common ---

variable "boot_disk_size" {
  description = "Boot disk size in GB for GKE nodes"
  type        = number
}

variable "allowed_api_cidrs" {
  description = "CIDR blocks allowed to access the GKE API server"
  type        = list(string)
}

variable "service_account_email" {
  description = "Service account email for GKE nodes"
  type        = string
}
