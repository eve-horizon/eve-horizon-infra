# Eve Horizon Infrastructure - GCP
# Root module for GCP-based Eve Horizon deployment
#
# Provisions a GKE Standard cluster with managed node pools, Cloud SQL
# PostgreSQL, Cloud DNS records, and optional GPU inference. Three node
# pools separate core services, agent runtimes, and user-deployed apps.

locals {
  effective_region                    = (var.region != null && trimspace(var.region) != "") ? trimspace(var.region) : var.gcp_region
  effective_default_node_machine_type = (var.compute_type != null && trimspace(var.compute_type) != "") ? trimspace(var.compute_type) : var.default_node_machine_type
  effective_boot_disk_size            = var.compute_disk_size_gb != null ? var.compute_disk_size_gb : var.boot_disk_size
  effective_db_tier                   = (var.database_instance_class != null && trimspace(var.database_instance_class) != "") ? trimspace(var.database_instance_class) : var.db_tier
  effective_ollama_machine_type       = (var.ollama_compute_type != null && trimspace(var.ollama_compute_type) != "") ? trimspace(var.ollama_compute_type) : var.ollama_machine_type
  effective_ollama_disk_size          = var.ollama_disk_size_gb != null ? var.ollama_disk_size_gb : var.ollama_disk_size
}

# -----------------------------------------------------------------------------
# Service Accounts
# -----------------------------------------------------------------------------

resource "google_service_account" "gke_nodes" {
  account_id   = "${var.name_prefix}-gke-nodes"
  display_name = "GKE nodes for ${var.name_prefix}"
}

resource "google_project_iam_member" "gke_log_writer" {
  project = var.gcp_project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_metric_writer" {
  project = var.gcp_project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# -----------------------------------------------------------------------------
# Network Module
# VPC, subnet, secondary ranges, Cloud NAT
# -----------------------------------------------------------------------------

module "network" {
  source = "./modules/network"

  name_prefix   = var.name_prefix
  subnet_cidr   = var.subnet_cidr
  pods_cidr     = var.pods_cidr
  services_cidr = var.services_cidr
}

# -----------------------------------------------------------------------------
# Cloud SQL Module
# PostgreSQL database instance
# -----------------------------------------------------------------------------

module "sql" {
  source = "./modules/sql"

  name_prefix         = var.name_prefix
  network_id          = module.network.network_id
  db_name             = var.db_name
  db_username         = var.db_username
  db_password         = var.db_password
  tier                = local.effective_db_tier
  deletion_protection = var.deletion_protection
}

# -----------------------------------------------------------------------------
# GKE Module
# Cluster + three node pools (default, agents, apps)
# -----------------------------------------------------------------------------

module "gke" {
  source = "./modules/gke"

  name_prefix               = var.name_prefix
  zone                      = var.gcp_zone
  network_name              = module.network.network_name
  subnet_name               = module.network.subnet_name
  pods_range_name           = module.network.pods_range_name
  services_range_name       = module.network.services_range_name
  default_node_machine_type = local.effective_default_node_machine_type
  default_node_count        = var.default_node_count
  default_node_min          = var.default_node_min
  default_node_max          = var.default_node_max
  agent_node_machine_type   = var.agent_node_machine_type
  agent_node_min            = var.agent_node_min
  agent_node_max            = var.agent_node_max
  apps_node_machine_type    = var.apps_node_machine_type
  apps_node_min             = var.apps_node_min
  apps_node_max             = var.apps_node_max
  boot_disk_size            = local.effective_boot_disk_size
  allowed_api_cidrs         = var.allowed_api_cidrs
  service_account_email     = google_service_account.gke_nodes.email
}

# -----------------------------------------------------------------------------
# DNS Module
# Cloud DNS records for the Eve Horizon domain
# -----------------------------------------------------------------------------

module "dns" {
  source = "./modules/dns"

  domain        = var.domain
  dns_zone_name = var.dns_zone_name
  public_ip     = module.gke.ingress_ip
}

# -----------------------------------------------------------------------------
# Ollama GPU Host Module (optional)
# On-demand spot GPU instance running Ollama
# -----------------------------------------------------------------------------

module "ollama" {
  count  = var.ollama_enabled ? 1 : 0
  source = "./modules/ollama"

  name_prefix          = var.name_prefix
  network_name         = module.network.network_name
  subnet_name          = module.network.subnet_name
  allowed_ssh_cidrs    = var.allowed_ssh_cidrs
  machine_type         = local.effective_ollama_machine_type
  gpu_type             = var.ollama_gpu_type
  disk_size            = local.effective_ollama_disk_size
  idle_timeout_minutes = var.ollama_idle_timeout_minutes
  ssh_public_key       = var.ssh_public_key
  region               = local.effective_region
  gke_node_cidr        = var.subnet_cidr
}

# Grant GKE node SA permission to resize Ollama MIG
resource "google_project_iam_member" "gke_ollama_wake" {
  count   = var.ollama_enabled ? 1 : 0
  project = var.gcp_project_id
  role    = "roles/compute.admin"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}
