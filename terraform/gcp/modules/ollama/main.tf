# Ollama GPU Host Module (GCP)
#
# On-demand GPU VM running Ollama behind a MIG (target_size 0).
# The instance starts when Eve API resizes MIG to 1, and auto-shuts down
# after a configurable idle timeout. Model weights persist on a dedicated
# persistent disk across stop/start cycles.

# -----------------------------------------------------------------------------
# GPU Zone Auto-Detection
# Pick the first zone in the region that supports the requested machine type.
# -----------------------------------------------------------------------------

data "google_compute_zones" "available" {
  region = var.region
}

data "google_compute_machine_types" "gpu" {
  for_each = toset(data.google_compute_zones.available.names)
  zone     = each.value
  filter   = "name = ${var.machine_type}"
}

locals {
  gpu_zone = [
    for z, mt in data.google_compute_machine_types.gpu :
    z if length(mt.machine_types) > 0
  ][0]
}

# -----------------------------------------------------------------------------
# Service Account
# -----------------------------------------------------------------------------

resource "google_service_account" "ollama" {
  account_id   = "${var.name_prefix}-ollama"
  display_name = "Ollama GPU host for ${var.name_prefix}"
}

resource "google_project_iam_member" "ollama_compute" {
  project = data.google_project.current.project_id
  role    = "roles/compute.admin"
  member  = "serviceAccount:${google_service_account.ollama.email}"
}

data "google_project" "current" {}

# -----------------------------------------------------------------------------
# Persistent Disk (model weights)
# -----------------------------------------------------------------------------

resource "google_compute_disk" "ollama_models" {
  name = "${var.name_prefix}-ollama-models"
  type = "pd-ssd"
  size = var.disk_size
  zone = local.gpu_zone
}

# -----------------------------------------------------------------------------
# Firewall Rules
# -----------------------------------------------------------------------------

resource "google_compute_firewall" "ollama_api" {
  name    = "${var.name_prefix}-ollama-api"
  network = var.network_name

  allow {
    protocol = "tcp"
    ports    = ["11434"]
  }

  source_ranges = [var.gke_node_cidr]
  target_tags   = ["ollama"]
}

resource "google_compute_firewall" "ollama_ssh" {
  name    = "${var.name_prefix}-ollama-ssh"
  network = var.network_name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.allowed_ssh_cidrs
  target_tags   = ["ollama"]
}

# -----------------------------------------------------------------------------
# Instance Template
# -----------------------------------------------------------------------------

resource "google_compute_instance_template" "ollama" {
  name_prefix  = "${var.name_prefix}-ollama-"
  machine_type = var.machine_type

  disk {
    source_image = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts"
    auto_delete  = true
    boot         = true
    disk_size_gb = 50
    disk_type    = "pd-ssd"
  }

  guest_accelerator {
    type  = var.gpu_type
    count = 1
  }

  scheduling {
    preemptible       = true
    automatic_restart = false
    # Required for GPU instances
    on_host_maintenance = "TERMINATE"
  }

  network_interface {
    network    = var.network_name
    subnetwork = var.subnet_name

    access_config {
      # Ephemeral public IP for model registry pulls
    }
  }

  service_account {
    email  = google_service_account.ollama.email
    scopes = ["cloud-platform"]
  }

  tags = ["ollama"]

  metadata = merge(
    {
      startup-script = templatefile("${path.module}/startup_script.sh.tpl", {
        disk_name            = google_compute_disk.ollama_models.name
        mig_name             = "${var.name_prefix}-ollama-mig"
        zone                 = local.gpu_zone
        idle_timeout_minutes = var.idle_timeout_minutes
      })
    },
    var.ssh_public_key != "" ? {
      ssh-keys = "ubuntu:${var.ssh_public_key}"
    } : {}
  )

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Managed Instance Group (target_size = 0, resting state: OFF)
# -----------------------------------------------------------------------------

resource "google_compute_instance_group_manager" "ollama" {
  name               = "${var.name_prefix}-ollama-mig"
  base_instance_name = "${var.name_prefix}-ollama"
  zone               = local.gpu_zone
  target_size        = 0

  version {
    instance_template = google_compute_instance_template.ollama.id
  }

  lifecycle {
    ignore_changes = [target_size]
  }
}
