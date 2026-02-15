# Network Module — VPC, subnet, secondary ranges, Cloud NAT
#
# GKE requires VPC-native networking with secondary IP ranges for pods and
# services. Cloud NAT provides egress for private nodes.

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------

resource "google_compute_network" "main" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
}

# -----------------------------------------------------------------------------
# Subnet with secondary ranges for GKE
# -----------------------------------------------------------------------------

resource "google_compute_subnetwork" "gke" {
  name          = "${var.name_prefix}-gke-subnet"
  network       = google_compute_network.main.id
  ip_cidr_range = var.subnet_cidr

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  private_ip_google_access = true
}

# -----------------------------------------------------------------------------
# Private Services Access (Cloud SQL VPC peering)
# -----------------------------------------------------------------------------

resource "google_compute_global_address" "private_services" {
  name          = "${var.name_prefix}-private-services"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.main.id
}

resource "google_service_networking_connection" "private" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services.name]
}

# -----------------------------------------------------------------------------
# Cloud NAT (egress for private GKE nodes)
# -----------------------------------------------------------------------------

resource "google_compute_router" "main" {
  name    = "${var.name_prefix}-router"
  network = google_compute_network.main.id
}

resource "google_compute_router_nat" "main" {
  name                               = "${var.name_prefix}-nat"
  router                             = google_compute_router.main.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = false
    filter = "ERRORS_ONLY"
  }
}

# -----------------------------------------------------------------------------
# Firewall — internal traffic
# -----------------------------------------------------------------------------

resource "google_compute_firewall" "allow_internal" {
  name    = "${var.name_prefix}-allow-internal"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [var.subnet_cidr]
}
