# GKE Module — Cluster + Three Node Pools
#
# GKE Standard cluster with a free zonal control plane and three node pools:
#   - default: always-on, runs core platform services (API, Worker, etc.)
#   - agents:  spot VMs, scales 0→N, tainted for agent runtimes + BuildKit
#   - apps:    spot VMs, scales 0→N, tainted for user-deployed app workloads

# -----------------------------------------------------------------------------
# GKE Cluster
# -----------------------------------------------------------------------------

resource "google_container_cluster" "main" {
  name     = "${var.name_prefix}-cluster"
  location = var.zone

  # We manage our own node pools — remove the default one
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = var.network_name
  subnetwork = var.subnet_name

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Restrict API access
  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.allowed_api_cidrs
      content {
        cidr_block = cidr_blocks.value
      }
    }
  }

  # Private nodes, public API endpoint
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  workload_identity_config {
    workload_pool = "${data.google_project.current.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  # Addons
  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    gcs_fuse_csi_driver_config {
      enabled = true
    }
    gcp_filestore_csi_driver_config {
      enabled = true
    }
  }

  # Ignore node pool changes (managed separately)
  lifecycle {
    ignore_changes = [initial_node_count]
  }
}

data "google_project" "current" {}

# -----------------------------------------------------------------------------
# Default Node Pool — Core Services (always-on)
# -----------------------------------------------------------------------------

resource "google_container_node_pool" "default" {
  name     = "default"
  cluster  = google_container_cluster.main.name
  location = var.zone

  initial_node_count = var.default_node_count

  autoscaling {
    min_node_count = var.default_node_min
    max_node_count = var.default_node_max
  }

  node_config {
    machine_type    = var.default_node_machine_type
    disk_size_gb    = var.boot_disk_size
    disk_type       = "pd-ssd"
    service_account = var.service_account_email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      pool = "default"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# -----------------------------------------------------------------------------
# Agents Node Pool — Spot VMs for agent runtimes + BuildKit
# -----------------------------------------------------------------------------

resource "google_container_node_pool" "agents" {
  name     = "agents"
  cluster  = google_container_cluster.main.name
  location = var.zone

  initial_node_count = 0

  autoscaling {
    min_node_count = var.agent_node_min
    max_node_count = var.agent_node_max
  }

  node_config {
    machine_type    = var.agent_node_machine_type
    disk_size_gb    = var.boot_disk_size
    disk_type       = "pd-ssd"
    spot            = true
    service_account = var.service_account_email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      pool = "agents"
    }

    taint {
      key    = "pool"
      value  = "agents"
      effect = "NO_SCHEDULE"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# -----------------------------------------------------------------------------
# Apps Node Pool — Spot VMs for user-deployed app workloads
# -----------------------------------------------------------------------------

resource "google_container_node_pool" "apps" {
  name     = "apps"
  cluster  = google_container_cluster.main.name
  location = var.zone

  initial_node_count = 0

  autoscaling {
    min_node_count = var.apps_node_min
    max_node_count = var.apps_node_max
  }

  node_config {
    machine_type    = var.apps_node_machine_type
    disk_size_gb    = var.boot_disk_size
    disk_type       = "pd-ssd"
    spot            = true
    service_account = var.service_account_email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      pool = "apps"
    }

    taint {
      key    = "pool"
      value  = "apps"
      effect = "NO_SCHEDULE"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# -----------------------------------------------------------------------------
# Static IP for Ingress Load Balancer
# -----------------------------------------------------------------------------

resource "google_compute_address" "ingress" {
  name   = "${var.name_prefix}-ingress-ip"
  region = replace(var.zone, "/-[a-z]$/", "")
}
