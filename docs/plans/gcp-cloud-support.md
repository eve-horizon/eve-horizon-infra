# Google Cloud Platform Support

**Date:** 2026-02-14
**Status:** Planned
**Scope:** This template repo (`eve-horizon/eve-horizon-infra`)

## Goal

Add full GCP support as a first-class alternative to AWS. An operator should
be able to set `cloud: gcp` in `platform.yaml` and deploy a complete Eve
Horizon instance on Google Cloud with the same operational experience: managed
Kubernetes, managed Postgres, DNS records, optional GPU inference, same CLI.

## Resolved Decisions

These were discussed and decided before writing this plan:

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| 1 | IAM scope | **Predefined roles** | Start broad (`roles/compute.admin`), tighten later once permission surface is understood. Simpler to maintain. |
| 2 | Cloud SQL connection | **Private IP via VPC peering** | Direct connection, no sidecar. Auth Proxy is overengineering for this use case. |
| 3 | Compute model | **GKE Standard** | Free control plane, node autoscaler, spot pools. ~$50/mo base vs ~$100 for a fixed GCE VM. Meaningful cost and scaling advantage over k3s-on-GCE. |
| 4 | Image registry | **GHCR only** | Cloud-agnostic, already works. Both AWS and GCP pull from the same registry. |
| 5 | GPU zone availability | **Auto-detect** | Query GCP API for GPU availability and select zone automatically. More robust than documenting zone lists. |
| 6 | Terraform state backend | **Local with GCS example** | Default to local state. Include `backend.tf.example` for GCS. |

## Design Principles

1. **Mirror, don't abstract.** GCP gets its own `terraform/gcp/` tree and
   `k8s/overlays/gcp/` directory. No cross-cloud abstraction layer.

2. **GCP-native where it matters.** Use GKE instead of porting k3s. The
   free control plane and node autoscaler are genuine advantages. Operators
   choosing GCP want GCP-native tooling, not an AWS pattern ported over.

3. **Same operational surface.** `bin/eve-infra` commands, deploy workflows,
   and `platform.yaml` schema work identically. The `cloud` field is the
   only switch.

4. **Prove it in staging first.** Ship with a working staging deployment
   before documenting as production-ready.

## Architecture — AWS vs GCP

```
                    AWS                          GCP
                    ───                          ───
Kubernetes     k3s on EC2 (self-managed)    GKE Standard (managed)
Nodes          Single EC2 instance          Node pools (autoscaler)
Spot nodes     N/A (single node)            Spot pools for agents + apps
Database       RDS PostgreSQL               Cloud SQL PostgreSQL
DNS            Route53                      Cloud DNS
Static IP      Elastic IP on EC2            Static IP on GKE ingress
TLS            cert-manager + Let's Encrypt cert-manager + Let's Encrypt
GPU (opt)      ASG spot (min=0, max=1)      MIG spot (size 0/1)
IAM            IAM Role + Instance Profile  Service Account
Registry       GHCR                         GHCR
```

### Key Architectural Difference: GKE vs k3s

AWS uses a single EC2 instance running k3s — the entire cluster is one
machine. GCP uses GKE Standard, which gives us:

- **Free managed control plane** (one zonal cluster per project)
- **Node autoscaler** — start with a small default pool, scale out
  automatically when agent runtimes need capacity
- **Spot node pools** — agent runtimes are stateless and restartable,
  ideal for 60-90% spot discounts
- **Managed upgrades** — no k3s maintenance, etcd backups, cert rotation
- **BuildKit works** — GKE Standard allows privileged containers
  (Autopilot does not, so we specifically target Standard)

The trade-off is operational divergence from AWS. The CLI needs a
GKE-aware kubeconfig path (`gcloud container clusters get-credentials`
instead of SCP from a VM). This is acceptable — the K8s API is the same
once connected.

## App Compute Contract

User-deployed apps (services defined in `.eve/manifest.yaml`) need compute
isolation from the Eve platform. This section defines the contract between
the manifest, the Worker, and the infrastructure.

### Compute Classes (Per-Service)

Apps declare sizing per-service in the manifest. The Worker translates
classes into substrate-native resource specs at deploy time.

```yaml
# .eve/manifest.yaml
services:
  api:
    build:
      context: ./apps/api
    x-eve:
      compute_class: medium    # small | medium | large | xlarge
```

| Class | CPU Request | Memory Request | CPU Limit | Memory Limit |
|-------|-------------|----------------|-----------|--------------|
| `small` | 0.25 | 512Mi | 0.5 | 1Gi |
| `medium` | 1 | 2Gi | 2 | 4Gi |
| `large` | 2 | 4Gi | 4 | 8Gi |
| `xlarge` | 4 | 8Gi | 8 | 16Gi |

Default (no `compute_class`): `small`.

### Cross-Substrate Translation

The manifest is substrate-agnostic. Each infrastructure backend translates
`compute_class` into the native resource model:

| Manifest | GKE (K8s) | ECS Fargate | k3s (K8s) |
|----------|-----------|-------------|-----------|
| `small` | `requests: 0.25c/512Mi` | 256 CPU / 512MB | `requests: 0.25c/512Mi` |
| `medium` | `requests: 1c/2Gi` | 1024 CPU / 2GB | `requests: 1c/2Gi` |
| `large` | `requests: 2c/4Gi` | 2048 CPU / 4GB | `requests: 2c/4Gi` |
| `xlarge` | `requests: 4c/8Gi` | 4096 CPU / 8GB | `requests: 4c/8Gi` |

### Infrastructure Responsibility

Each infra backend must provision capacity that serves the apps pool:

- **GKE** — `apps` node pool, spot VMs, autoscaling 0→N, tainted
  `pool=apps:NoSchedule`. Worker injects tolerations + node selector.
- **ECS** — Fargate capacity provider (or EC2 autoscaling group). Worker
  creates task definitions with CPU/memory matching the class.
- **k3s** — Same single node. Worker sets resource requests to prevent
  overcommit. No node targeting needed.

### Worker Responsibilities (Platform Change)

When deploying an app service on Kubernetes substrates, the Worker must:

1. Set `resources.requests` and `resources.limits` from the compute class
2. Inject `nodeSelector: { pool: apps }` (GKE only)
3. Inject toleration for `pool=apps:NoSchedule` (GKE only)
4. Detect substrate from platform config and apply the right translation

This is a platform-level change (in `eve-horizon`, not this infra repo)
but is documented here to define the contract the infra must fulfill.

---

## What Needs to Change

### 1. New: `terraform/gcp/` — Root Module

```
terraform/gcp/
  main.tf                  # Module composition + service accounts
  variables.tf             # Input variables
  outputs.tf               # Outputs (cluster, DB, DNS, etc.)
  providers.tf             # google + google-beta providers
  backend.tf.example       # GCS backend template
  terraform.tfvars.example # Annotated example
  modules/
    network/               # VPC, subnets, firewall rules, Cloud NAT
    gke/                   # GKE cluster, node pools
    sql/                   # Cloud SQL PostgreSQL
    dns/                   # Cloud DNS records
    ollama/                # Optional GPU MIG (conditional)
```

#### `providers.tf`

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region

  default_labels = {
    project     = var.project_name
    environment = var.environment
    managed-by  = "terraform"
  }
}

provider "google-beta" {
  project = var.gcp_project_id
  region  = var.gcp_region
}
```

#### `backend.tf.example`

```hcl
# Uncomment and configure for remote state storage.
# Create the bucket first: gsutil mb gs://YOUR_BUCKET_NAME
#
# terraform {
#   backend "gcs" {
#     bucket = "eve-horizon-tfstate"
#     prefix = "terraform/state"
#   }
# }
```

#### `variables.tf`

```hcl
# --- Identity ---
variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region (e.g. us-central1, europe-west1)"
  type        = string
  default     = "us-central1"
}

variable "gcp_zone" {
  description = "GCP zone for zonal GKE cluster (e.g. us-central1-a)"
  type        = string
  default     = "us-central1-a"
}

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
}

# --- Network ---
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
}

variable "allowed_api_cidrs" {
  description = "CIDR blocks allowed to access the GKE API server"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# --- GKE ---
variable "default_node_machine_type" {
  description = "Machine type for the default (system) node pool"
  type        = string
  default     = "e2-standard-2"  # 2 vCPU, 8 GB — runs core services
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
  default     = 3
}

variable "agent_node_machine_type" {
  description = "Machine type for the agent-runtime spot node pool"
  type        = string
  default     = "e2-standard-4"  # 4 vCPU, 16 GB — runs agent workloads
}

variable "agent_node_min" {
  description = "Minimum nodes in agent spot pool (can be 0)"
  type        = number
  default     = 0
}

variable "agent_node_max" {
  description = "Maximum nodes in agent spot pool"
  type        = number
  default     = 3
}

variable "apps_node_machine_type" {
  description = "Machine type for the user app spot node pool"
  type        = string
  default     = "e2-standard-2"  # 2 vCPU, 8 GB — runs user-deployed apps
}

variable "apps_node_min" {
  description = "Minimum nodes in apps spot pool (can be 0)"
  type        = number
  default     = 0
}

variable "apps_node_max" {
  description = "Maximum nodes in apps spot pool"
  type        = number
  default     = 5
}

variable "boot_disk_size" {
  description = "Boot disk size in GB for GKE nodes"
  type        = number
  default     = 50
}

variable "ssh_public_key" {
  description = "SSH public key for node access (optional, for debugging)"
  type        = string
  sensitive   = true
  default     = ""
}

# --- Domain ---
variable "domain" {
  description = "Eve Horizon domain name"
  type        = string
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone name"
  type        = string
}

# --- Database ---
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
  description = "Cloud SQL machine tier"
  type        = string
  default     = "db-f1-micro"
}

variable "deletion_protection" {
  description = "Enable deletion protection on Cloud SQL"
  type        = bool
  default     = false
}

# --- Ollama GPU (optional) ---
variable "ollama_enabled" {
  description = "Enable on-demand Ollama GPU host"
  type        = bool
  default     = false
}

variable "ollama_machine_type" {
  description = "GCE machine type for Ollama GPU host"
  type        = string
  default     = "g2-standard-4"
}

variable "ollama_gpu_type" {
  description = "GPU accelerator type"
  type        = string
  default     = "nvidia-l4"
}

variable "ollama_disk_size" {
  description = "Persistent disk size in GB for model storage"
  type        = number
  default     = 100
}

variable "ollama_idle_timeout_minutes" {
  description = "Minutes of inactivity before GPU auto-shuts down"
  type        = number
  default     = 30
}
```

---

### 2. New: `terraform/gcp/modules/network/`

GCP networking for GKE — VPC, subnets with secondary ranges for pods/services,
firewall rules, Cloud NAT for egress from private nodes.

**Resources:**
- `google_compute_network.main` — VPC (`auto_create_subnetworks = false`)
- `google_compute_subnetwork.gke` — Subnet with secondary IP ranges:
  - Primary range: node IPs
  - `pods` secondary range: GKE pod IPs
  - `services` secondary range: GKE service IPs
- `google_compute_global_address.private_services` — Private IP range for
  Cloud SQL VPC peering
- `google_service_networking_connection.private` — VPC peering for Cloud SQL
- `google_compute_router.main` — Cloud Router (for Cloud NAT)
- `google_compute_router_nat.main` — Cloud NAT (egress for private nodes)
- `google_compute_firewall.allow_ssh` — SSH from allowed CIDRs
- `google_compute_firewall.allow_internal` — Internal VPC traffic

**Outputs:** `network_id`, `network_name`, `subnet_id`, `subnet_name`,
`pods_range_name`, `services_range_name`

**Key difference from AWS:** GKE requires secondary IP ranges on the subnet
for pods and services (VPC-native networking). Cloud NAT provides egress for
nodes without public IPs. No IGW or route tables needed.

---

### 3. New: `terraform/gcp/modules/gke/`

GKE Standard cluster with three node pools: a small default pool for core
platform services, a spot pool for agent runtimes, and a spot pool for
user-deployed app workloads.

**Resources:**
- `google_container_cluster.main` — GKE Standard cluster:
  - `location` — Zonal (free control plane)
  - `remove_default_node_pool = true` — We manage our own pools
  - `initial_node_count = 1` — Required but immediately removed
  - `networking_mode = "VPC_NATIVE"` — Use subnet secondary ranges
  - `ip_allocation_policy` — Pod and service CIDR ranges
  - `master_authorized_networks_config` — Restrict API access
  - `private_cluster_config` — Nodes get private IPs only
    - `enable_private_nodes = true`
    - `enable_private_endpoint = false` — Public API endpoint
    - `master_ipv4_cidr_block = "172.16.0.0/28"`
  - `workload_identity_config` — Enable Workload Identity
  - `release_channel = "REGULAR"` — Managed upgrades
  - Addons: `http_load_balancing`, `horizontal_pod_autoscaling`,
    `gcs_fuse_csi_driver_config`, `filestore_csi_driver_config`

- `google_container_node_pool.default` — Core services pool:
  - Machine type: `e2-standard-2` (2 vCPU, 8 GB)
  - Autoscaling: 1–3 nodes
  - On-demand pricing
  - Labels: `pool = "default"`
  - OAuth scopes: `cloud-platform`
  - Service account: Dedicated SA

- `google_container_node_pool.agents` — Agent runtime pool:
  - Machine type: `e2-standard-4` (4 vCPU, 16 GB)
  - Autoscaling: 0–3 nodes
  - **Spot VMs** (`spot = true`) — 60-90% cost savings
  - Labels: `pool = "agents"`
  - Taints: `pool=agents:NoSchedule` — Only agent runtimes schedule here
  - OAuth scopes: `cloud-platform`

- `google_container_node_pool.apps` — User app workload pool:
  - Machine type: `e2-standard-2` (2 vCPU, 8 GB) — configurable
  - Autoscaling: 0–5 nodes
  - **Spot VMs** (`spot = true`) — apps are stateless and restartable
  - Labels: `pool = "apps"`
  - Taints: `pool=apps:NoSchedule` — Only user-deployed apps schedule here
  - OAuth scopes: `cloud-platform`

- `google_compute_address.ingress` — Regional static IP for the
  nginx-ingress LoadBalancer service. Reserved in Terraform so DNS can
  point to a stable address. Passed to the nginx-ingress Helm install
  via `controller.service.loadBalancerIP`.

**Variables:** `name_prefix`, `network_name`, `subnet_name`,
`pods_range_name`, `services_range_name`, `default_node_machine_type`,
`default_node_count`, `default_node_min`, `default_node_max`,
`agent_node_machine_type`, `agent_node_min`, `agent_node_max`,
`apps_node_machine_type`, `apps_node_min`, `apps_node_max`,
`boot_disk_size`, `allowed_api_cidrs`, `service_account_email`, `zone`

**Outputs:** `cluster_name`, `cluster_endpoint`, `cluster_ca_certificate`,
`kubeconfig_command`, `ingress_ip`

#### Node Pool Design

```
┌──────────────────────────────────────────────────────────────────────────┐
│  GKE Cluster (free zonal control plane)                                  │
│                                                                          │
│  ┌──────────────────┐  ┌──────────────────┐  ┌────────────────────────┐ │
│  │ Default Pool      │  │ Agents Pool      │  │ Apps Pool              │ │
│  │ e2-standard-2     │  │ e2-standard-4    │  │ e2-standard-2          │ │
│  │ 1-3 nodes         │  │ 0-3 nodes        │  │ 0-5 nodes              │ │
│  │ On-demand          │  │ Spot (~70% off)  │  │ Spot (~70% off)        │ │
│  │                    │  │                  │  │                        │ │
│  │ • API              │  │ • Agent Runtime  │  │ • User app services    │ │
│  │ • Worker           │  │ • BuildKit       │  │ • Deployed via Worker  │ │
│  │ • Orchestrator     │  │                  │  │                        │ │
│  │ • Gateway          │  │ Taint: agents    │  │ Taint: apps            │ │
│  │                    │  │ Scales to 0      │  │ Scales to 0            │ │
│  └──────────────────┘  └──────────────────┘  └────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────┘
```

Core services (API, Worker, Orchestrator, Gateway) run on the always-on
default pool. Agent runtimes and BuildKit tolerate the `pool=agents` taint
and schedule onto the agents spot pool. User-deployed apps tolerate the
`pool=apps` taint and schedule onto the apps spot pool. Both spot pools
scale from 0 based on demand — at idle, only the default pool runs.

---

### 4. New: `terraform/gcp/modules/sql/`

Cloud SQL for PostgreSQL, equivalent to AWS RDS.

**Resources:**
- `google_sql_database_instance.main` — PostgreSQL 15:
  - `database_version = "POSTGRES_15"`
  - `tier` — Configurable (default `db-f1-micro`)
  - `ip_configuration`:
    - `private_network` — VPC peering (no public IP)
    - `ipv4_enabled = false`
  - `backup_configuration`:
    - `enabled = true`
    - `start_time = "03:00"`
    - `point_in_time_recovery_enabled = true`
  - `insights_config.query_insights_enabled = true`
  - `deletion_protection` — Configurable
  - `disk_autoresize = true`
  - `disk_size = 20` — Initial GB
  - `disk_type = "PD_SSD"`
  - `availability_type = "ZONAL"`
- `google_sql_database.main` — Database
- `google_sql_user.main` — User with password

**Variables:** `name_prefix`, `network_id`, `db_name`, `db_username`,
`db_password`, `tier`, `deletion_protection`

**Outputs:** `connection_name`, `private_ip`, `port`, `database_name`

**Key difference from RDS:** No subnet group. Uses Private Services Access
(VPC peering) configured in the network module. Connection via private IP
directly — no security group needed.

---

### 5. New: `terraform/gcp/modules/dns/`

Cloud DNS records, equivalent to Route53.

**Resources:**
- `data.google_dns_managed_zone.main` — Look up existing zone
- `google_dns_record_set.apex` — A record → GKE ingress IP
- `google_dns_record_set.wildcard` — Wildcard A record → GKE ingress IP

**Variables:** `domain`, `dns_zone_name`, `public_ip`

**Outputs:** `apex_fqdn`, `wildcard_fqdn`

**Note:** The `public_ip` here points to the GKE ingress load balancer IP
(provisioned by the Ingress resource or a static IP reservation), not a VM.
This differs from AWS where DNS points to the EC2 Elastic IP.

---

### 6. New: `terraform/gcp/modules/ollama/` (Conditional)

On-demand GPU VM for Ollama, equivalent to the AWS Ollama module. This runs
**outside GKE** as a standalone GCE instance (same pattern as AWS — the GPU
host is not a Kubernetes node).

**Resources:**
- `google_service_account.ollama` — Dedicated SA for the Ollama VM,
  with `roles/compute.instanceGroupManager.admin` scoped to the MIG
  so the idle-shutdown script can resize itself to 0
- `google_compute_disk.ollama_models` — Persistent SSD for model weights
- `google_compute_firewall.ollama_api` — Port 11434 from GKE node IPs
- `google_compute_firewall.ollama_ssh` — SSH from allowed CIDRs
- `google_compute_instance_template.ollama` — Template:
  - `guest_accelerator` with GPU type
  - `scheduling.preemptible = true` (Spot)
  - `scheduling.on_host_maintenance = "TERMINATE"` (required for GPU)
  - Startup script: NVIDIA driver, Ollama, disk mount, idle timer
  - `service_account.email = google_service_account.ollama.email`
  - Network tags: `["ollama"]`
- `google_compute_instance_group_manager.ollama` — MIG:
  - `target_size = 0` (resting state: OFF)
  - Single zone
- `google_project_iam_member.ollama_compute` — Grant the Ollama SA
  `roles/compute.admin` for MIG self-resize

**GPU zone auto-detection:**

```hcl
# Find a zone in the region that has the requested GPU type available
data "google_compute_zones" "available" {
  region = var.region
}

data "google_compute_machine_types" "gpu" {
  for_each = toset(data.google_compute_zones.available.names)
  zone     = each.value
  filter   = "name = ${var.machine_type}"
}

locals {
  # Pick the first zone that supports the requested machine type
  gpu_zone = [for z, mt in data.google_compute_machine_types.gpu :
    z if length(mt.machine_types) > 0
  ][0]
}
```

This automatically selects a zone with GPU availability rather than
requiring operators to know which zones have L4s.

**Ollama startup script** (`startup_script.sh.tpl`):

```bash
#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/ollama-startup.log) 2>&1

# --- GPU Driver ---
apt-get update
apt-get install -y nvidia-headless-550-server nvidia-utils-550-server
modprobe nvidia
nvidia-smi

# --- Attach persistent disk ---
DISK_NAME="${disk_name}"
DEVICE="/dev/disk/by-id/google-$DISK_NAME"
until [ -e "$DEVICE" ]; do sleep 2; done
if ! blkid "$DEVICE"; then mkfs.ext4 -L ollama-models "$DEVICE"; fi
mkdir -p /data/ollama && mount "$DEVICE" /data/ollama

# --- Ollama ---
curl -fsSL https://ollama.com/install.sh | sh
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_MODELS=/data/ollama/models"
EOF
systemctl daemon-reload && systemctl enable --now ollama
until curl -sf http://localhost:11434/api/tags > /dev/null; do sleep 3; done

# --- Pre-pull models ---
ollama pull llama3.3:70b-instruct-q4_K_M
ollama pull qwen2.5-coder:32b-instruct-q4_K_M

# --- Idle auto-shutdown ---
cat > /usr/local/bin/ollama-idle-check.sh <<'IDLE'
#!/bin/bash
TIMEOUT_MINUTES=${idle_timeout_minutes}
LAST_REQUEST=$(journalctl -u ollama --since "$TIMEOUT_MINUTES minutes ago" \
  --no-pager -o cat | grep -c "request completed" || true)
if [ "$LAST_REQUEST" -eq 0 ]; then
  gcloud compute instance-groups managed resize ${mig_name} \
    --size=0 --zone=${zone} --quiet
  shutdown -h now
fi
IDLE
chmod +x /usr/local/bin/ollama-idle-check.sh

cat > /etc/systemd/system/ollama-idle.timer <<EOF
[Unit]
Description=Check Ollama idle every 5 minutes
[Timer]
OnBootSec=10min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/ollama-idle.service <<EOF
[Unit]
Description=Ollama idle shutdown check
[Service]
Type=oneshot
ExecStart=/usr/local/bin/ollama-idle-check.sh
EOF
systemctl enable --now ollama-idle.timer
```

---

### 7. New: `terraform/gcp/main.tf` — Root Composition

```hcl
# --- Service Accounts ---
resource "google_service_account" "gke_nodes" {
  account_id   = "${var.name_prefix}-gke-nodes"
  display_name = "GKE nodes for ${var.name_prefix}"
}

# Predefined roles for GKE node SA
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

# --- Modules ---
module "network" {
  source        = "./modules/network"
  name_prefix   = var.name_prefix
  subnet_cidr   = var.subnet_cidr
  pods_cidr     = var.pods_cidr
  services_cidr = var.services_cidr
}

module "sql" {
  source              = "./modules/sql"
  name_prefix         = var.name_prefix
  network_id          = module.network.network_id
  db_name             = var.db_name
  db_username         = var.db_username
  db_password         = var.db_password
  tier                = var.db_tier
  deletion_protection = var.deletion_protection
}

module "gke" {
  source                     = "./modules/gke"
  name_prefix                = var.name_prefix
  zone                       = var.gcp_zone
  network_name               = module.network.network_name
  subnet_name                = module.network.subnet_name
  pods_range_name            = module.network.pods_range_name
  services_range_name        = module.network.services_range_name
  default_node_machine_type  = var.default_node_machine_type
  default_node_count         = var.default_node_count
  default_node_min           = var.default_node_min
  default_node_max           = var.default_node_max
  agent_node_machine_type    = var.agent_node_machine_type
  agent_node_min             = var.agent_node_min
  agent_node_max             = var.agent_node_max
  apps_node_machine_type     = var.apps_node_machine_type
  apps_node_min              = var.apps_node_min
  apps_node_max              = var.apps_node_max
  boot_disk_size             = var.boot_disk_size
  allowed_api_cidrs          = var.allowed_api_cidrs
  service_account_email      = google_service_account.gke_nodes.email
}

module "dns" {
  source        = "./modules/dns"
  domain        = var.domain
  dns_zone_name = var.dns_zone_name
  public_ip     = module.gke.ingress_ip
}

# --- Ollama (conditional) ---
module "ollama" {
  count  = var.ollama_enabled ? 1 : 0
  source = "./modules/ollama"

  name_prefix          = var.name_prefix
  network_name         = module.network.network_name
  subnet_name          = module.network.subnet_name
  allowed_ssh_cidrs    = var.allowed_ssh_cidrs
  machine_type         = var.ollama_machine_type
  gpu_type             = var.ollama_gpu_type
  disk_size            = var.ollama_disk_size
  idle_timeout_minutes = var.ollama_idle_timeout_minutes
  ssh_public_key       = var.ssh_public_key
  region               = var.gcp_region
  gke_node_cidr        = var.subnet_cidr  # For firewall source range
}

# Grant GKE node SA permission to resize Ollama MIG
resource "google_project_iam_member" "gke_ollama_wake" {
  count   = var.ollama_enabled ? 1 : 0
  project = var.gcp_project_id
  role    = "roles/compute.admin"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}
```

#### `outputs.tf`

```hcl
output "cluster_name" {
  description = "GKE cluster name"
  value       = module.gke.cluster_name
}

output "kubeconfig_command" {
  description = "Command to configure kubectl"
  value       = "gcloud container clusters get-credentials ${module.gke.cluster_name} --zone ${var.gcp_zone} --project ${var.gcp_project_id}"
}

output "ingress_ip" {
  description = "Static IP for the ingress load balancer"
  value       = module.gke.ingress_ip
}

output "database_url" {
  description = "PostgreSQL connection URL"
  value       = "postgres://${var.db_username}:${var.db_password}@${module.sql.private_ip}:5432/${var.db_name}"
  sensitive   = true
}

output "cloud_sql_private_ip" {
  description = "Cloud SQL private IP address"
  value       = module.sql.private_ip
}

output "api_url" {
  description = "Eve Horizon API URL"
  value       = "https://${var.domain}"
}

output "ssh_command" {
  description = "SSH to GKE nodes (debugging only)"
  value       = "gcloud compute ssh --project=${var.gcp_project_id} --zone=ZONE NODE_NAME"
}

output "ollama_mig_name" {
  description = "MIG name for Ollama GPU (null if disabled)"
  value       = var.ollama_enabled ? module.ollama[0].mig_name : null
}
```

---

### 8. New: `k8s/overlays/gcp/`

Parallel to `k8s/overlays/aws/`. Same pattern: remove in-cluster Postgres,
patch images and DATABASE_URL, adjust ingress.

```
k8s/overlays/gcp/
  kustomization.yaml
  api-deployment-patch.yaml
  worker-deployment-patch.yaml
  orchestrator-deployment-patch.yaml
  gateway-deployment-patch.yaml
  agent-runtime-patch.yaml
  buildkit-patch.yaml
  db-migrate-job-patch.yaml
  api-ingress-patch.yaml
  gateway-ingress-patch.yaml
  remove-postgres-statefulset.yaml
  remove-postgres-service.yaml
  remove-postgres-secret.yaml
```

**Differences from AWS overlay:**

- **DATABASE_URL** placeholder points to Cloud SQL private IP
- **Ingress class**: AWS uses `traefik` (k3s default). GKE uses the
  built-in GCE ingress controller or nginx. Patches use
  `kubernetes.io/ingress.class: gce` or install nginx-ingress for Traefik
  parity. **Recommendation: install nginx-ingress via Helm in setup.sh
  for consistency** — it works identically on both clouds.
- **Agent runtime node affinity**: Add `nodeSelector` or `tolerations`
  for the `pool=agents` taint so agent-runtime pods schedule onto spot nodes
- **StorageClass**: Agent runtime PVC uses ReadWriteMany. On GKE, this
  requires Filestore CSI driver. Add a `StorageClass` resource for
  Filestore, and patch the PVC to reference it.

#### Agent Runtime Spot Pool Patch

```yaml
# agent-runtime-patch.yaml (GCP additions beyond AWS)
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: eve-agent-runtime
  namespace: eve
spec:
  template:
    spec:
      tolerations:
        - key: pool
          operator: Equal
          value: agents
          effect: NoSchedule
      nodeSelector:
        pool: agents
```

#### BuildKit Spot Pool Patch

```yaml
# buildkit-patch.yaml — schedule BuildKit onto agents spot pool
apiVersion: apps/v1
kind: Deployment
metadata:
  name: eve-buildkit
  namespace: eve
spec:
  template:
    spec:
      tolerations:
        - key: pool
          operator: Equal
          value: agents
          effect: NoSchedule
      nodeSelector:
        pool: agents
```

#### Filestore StorageClass

```yaml
# filestore-storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: filestore-rwx
provisioner: filestore.csi.storage.gke.io
parameters:
  tier: standard
  network: default
volumeBindingMode: Immediate
allowVolumeExpansion: true
```

---

### 9. Edit: `config/platform.yaml`

Add GCP-specific fields, mark GCP as supported.

```yaml
# Cloud provider.
#   aws  - Amazon Web Services (EC2 + RDS + Route53 on k3s)
#   gcp  - Google Cloud Platform (GKE + Cloud SQL + Cloud DNS)
cloud: aws                              # [REQUIRED] aws | gcp

# --- AWS-specific ---
route53_zone_id: ""                     # [REQUIRED for AWS]

# --- GCP-specific ---
gcp_project_id: ""                      # [REQUIRED for GCP]
dns_zone_name: ""                       # [REQUIRED for GCP] Cloud DNS zone name

database:
  # rds       - AWS RDS managed PostgreSQL
  # cloud-sql - GCP Cloud SQL managed PostgreSQL
  # in-cluster - Dev-only PostgreSQL inside Kubernetes
  # external  - Bring your own PostgreSQL
  provider: rds                         # [REQUIRED] rds | cloud-sql | in-cluster | external

  # Instance class / tier.
  #   AWS:  db.t3.micro, db.t3.medium, db.r6i.large
  #   GCP:  db-f1-micro, db-custom-2-8192, db-custom-4-16384
  instance_class: db.t3.micro           # [OPTIONAL]

compute:
  # Machine type for the primary compute node(s).
  #   AWS (EC2): t3.large, m6i.xlarge, m6i.2xlarge
  #   GCP (GKE): e2-standard-2, e2-standard-4, e2-standard-8
  type: m6i.xlarge                      # [REQUIRED]
```

---

### 10. Edit: `bin/eve-infra`

#### a. `cmd_db_backup()` — Add Cloud SQL case

```bash
cloud-sql)
  info "Cloud SQL backup:"
  info "  gcloud sql backups create --instance=\${INSTANCE_NAME}"
  info "  gcloud sql backups list --instance=\${INSTANCE_NAME}"
  ;;
```

#### b. Kubeconfig detection

The CLI currently looks for `config/kubeconfig.yaml`. For GKE, operators
run `gcloud container clusters get-credentials` which writes to
`~/.kube/config`. The CLI should detect this:

```bash
# In the kubeconfig resolution logic:
if [ -f "$REPO_ROOT/config/kubeconfig.yaml" ]; then
  export KUBECONFIG="$REPO_ROOT/config/kubeconfig.yaml"
elif [ "$CLOUD" = "gcp" ] && command -v gcloud &> /dev/null; then
  # GKE: kubeconfig is managed by gcloud, use default ~/.kube/config
  :
fi
```

#### c. No other changes needed

`deploy`, `health`, `logs`, `restart`, `secrets`, `sync` — all
cloud-agnostic kubectl/kustomize operations.

---

### 11. Edit: `.github/workflows/deploy.yml`

Add conditional GCP authentication step:

```yaml
- name: Authenticate to GCP
  if: env.CLOUD == 'gcp'
  uses: google-github-actions/auth@v2
  with:
    credentials_json: ${{ secrets.GCP_SA_KEY }}

- name: Configure GKE kubeconfig
  if: env.CLOUD == 'gcp'
  run: |
    gcloud container clusters get-credentials ${{ env.CLUSTER_NAME }} \
      --zone ${{ env.GCP_ZONE }} \
      --project ${{ env.GCP_PROJECT_ID }}
```

---

### 12. Edit: `scripts/setup.sh`

The setup script installs cert-manager and creates pull secrets. For GKE,
it also needs to:

1. **Install nginx-ingress** (GKE doesn't include Traefik like k3s)
2. **Create the `eve` namespace** (k3s startup script does this; GKE needs
   it in setup)

Note: Filestore CSI driver is enabled as a GKE addon in Terraform
(`filestore_csi_driver_config`), not in setup.sh.

Add cloud-conditional blocks:

```bash
CLOUD=$(grep '^cloud:' "$CONFIG_FILE" | awk '{print $2}')

if [ "$CLOUD" = "gcp" ]; then
  INGRESS_IP=$(terraform -chdir=terraform/gcp output -raw ingress_ip 2>/dev/null || true)

  info "Installing nginx-ingress controller..."
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    ${INGRESS_IP:+--set controller.service.loadBalancerIP="$INGRESS_IP"}

  info "Creating eve namespace..."
  kubectl create namespace eve --dry-run=client -o yaml | kubectl apply -f -
fi
```

---

### 13. New: `terraform/gcp/terraform.tfvars.example`

```hcl
# =============================================================================
# Eve Horizon — GCP Terraform Configuration
# =============================================================================

# --- GCP Project ---
gcp_project_id = "my-project-123"
gcp_region     = "us-central1"
gcp_zone       = "us-central1-a"          # Zonal cluster (free control plane)

# --- Identity ---
name_prefix = "eve-staging"
environment = "staging"

# --- Network ---
allowed_ssh_cidrs = ["0.0.0.0/0"]       # CHANGE THIS — restrict to your IP
allowed_api_cidrs = ["0.0.0.0/0"]       # CHANGE THIS — restrict K8s API access

# --- GKE Node Pools ---
# Default pool runs core services (API, Worker, Orchestrator, Gateway)
default_node_machine_type = "e2-standard-2"  # 2 vCPU, 8 GB
default_node_min = 1
default_node_max = 3

# Agent pool runs agent-runtime pods on spot VMs (60-90% cheaper)
agent_node_machine_type = "e2-standard-4"    # 4 vCPU, 16 GB
agent_node_min = 0                           # Scales to zero when idle
agent_node_max = 3

# Apps pool runs user-deployed app services on spot VMs
apps_node_machine_type = "e2-standard-2"     # 2 vCPU, 8 GB
apps_node_min = 0                            # Scales to zero when idle
apps_node_max = 5

boot_disk_size = 50

# --- Domain ---
domain        = "eve.example.com"
dns_zone_name = "example-com"           # Cloud DNS managed zone name

# --- Database ---
db_password = "CHANGE_ME"
# db_tier   = "db-f1-micro"             # Dev/staging
# db_tier   = "db-custom-2-8192"        # Production (2 vCPU, 8 GB)

# --- Ollama GPU (optional) ---
# ollama_enabled              = true
# ollama_machine_type         = "g2-standard-4"
# ollama_gpu_type             = "nvidia-l4"
# ollama_disk_size            = 100
# ollama_idle_timeout_minutes = 30
```

---

### 14. New: `docs/deployment-gcp.md`

GCP deployment guide covering:

1. Prerequisites (`gcloud` CLI, GCP project, domain)
2. Enable required APIs
3. Create Cloud DNS zone (`gcloud dns managed-zones create`)
4. Configure `terraform.tfvars`
5. `terraform init && terraform apply`
6. Get kubeconfig: `gcloud container clusters get-credentials`
7. Run `scripts/setup.sh` (installs cert-manager, nginx-ingress, namespaces)
8. Configure `config/secrets.env`
9. Deploy: `./bin/eve-infra deploy`
10. Verify: `./bin/eve-infra health`
11. Optional: Enable Ollama GPU

---

## File Change Summary

| File | Change | Sync Tier |
|------|--------|-----------|
| `terraform/gcp/main.tf` | **New** | always |
| `terraform/gcp/variables.tf` | **New** | always |
| `terraform/gcp/outputs.tf` | **New** | always |
| `terraform/gcp/providers.tf` | **New** | always |
| `terraform/gcp/backend.tf.example` | **New** | always |
| `terraform/gcp/terraform.tfvars.example` | **New** | never |
| `terraform/gcp/modules/network/*.tf` (3 files) | **New** | always |
| `terraform/gcp/modules/gke/*.tf` (3 files) | **New** | always |
| `terraform/gcp/modules/sql/*.tf` (3 files) | **New** | always |
| `terraform/gcp/modules/dns/*.tf` (3 files) | **New** | always |
| `terraform/gcp/modules/ollama/*.tf` (3 files) | **New** | always |
| `terraform/gcp/modules/ollama/startup_script.sh.tpl` | **New** | always |
| `k8s/overlays/gcp/kustomization.yaml` | **New** | ask |
| `k8s/overlays/gcp/*-patch.yaml` (12 files, incl. buildkit) | **New** | ask |
| `k8s/overlays/gcp/filestore-storageclass.yaml` | **New** | ask |
| `config/platform.yaml` | **Edit** | never |
| `bin/eve-infra` | **Edit** | always |
| `scripts/setup.sh` | **Edit** | always |
| `.github/workflows/deploy.yml` | **Edit** | always |
| `docs/deployment-gcp.md` | **New** | ask |
| `DEPLOYMENT.md` | **Edit** | ask |
| `README.md` | **Edit** | ask |
| `CLAUDE.md` | **Edit** | ask |

**~35 new files, ~7 edited files**

## Implementation Order

### Phase 1 — Network + GKE Cluster (get a running cluster)

1. `terraform/gcp/modules/network/` — VPC, subnet, secondary ranges, NAT
2. `terraform/gcp/modules/gke/` — Cluster, node pools
3. `terraform/gcp/providers.tf` + root `main.tf` (network + GKE only)
4. Service account + IAM bindings
5. **Checkpoint:** `gcloud container clusters get-credentials`, `kubectl get nodes`

### Phase 2 — Managed Database

6. `terraform/gcp/modules/sql/` — Cloud SQL instance, database, user
7. Wire into root `main.tf`, add DATABASE_URL output
8. **Checkpoint:** `psql` from a GKE pod to Cloud SQL private IP

### Phase 3 — DNS + K8s Overlay + Setup

9. `terraform/gcp/modules/dns/` — Cloud DNS records
10. `scripts/setup.sh` — Add nginx-ingress, namespace creation for GKE
11. `k8s/overlays/gcp/` — Patches, Filestore StorageClass, ingress config
12. **Checkpoint:** Full Eve deployment accessible at domain

### Phase 4 — GPU (Optional)

13. `terraform/gcp/modules/ollama/` — MIG, template, disk, firewall, auto-detect zone
14. Wire into root `main.tf` with conditional
15. **Checkpoint:** GPU instance launches and serves inference

### Phase 5 — Polish

16. `config/platform.yaml` — Add GCP fields
17. `bin/eve-infra` — Cloud SQL backup case, kubeconfig detection
18. `.github/workflows/deploy.yml` — GCP auth step
19. `terraform/gcp/terraform.tfvars.example` + `backend.tf.example`
20. `docs/deployment-gcp.md` — Deployment guide
21. Update `README.md`, `CLAUDE.md`, `DEPLOYMENT.md`

## Cost Comparison (Staging)

| Component | AWS (k3s on EC2) | GCP (GKE Standard) |
|-----------|-----------------|---------------------|
| Control plane | N/A (k3s) | Free (1 zonal cluster) |
| Core nodes | m6i.xlarge ~$140/mo | 1× e2-standard-2 ~$50/mo |
| Agent nodes | (included above) | 0-3× e2-standard-4 spot ~$30/mo each |
| App nodes | (included above) | 0-5× e2-standard-2 spot ~$15/mo each |
| Database | db.t3.micro free tier | db-f1-micro ~$8/mo |
| Static IP | $3.60/mo | Free (attached to LB) |
| DNS | $0.50/zone/mo | $0.20/zone/mo |
| Storage | ~$4/mo (gp3) | ~$8.50/mo (pd-ssd) |
| **Minimum** | **~$148/mo** | **~$67/mo** |
| **With agents active** | **~$148/mo** (same box) | **~$97/mo** (1 agent spot) |
| **With apps active** | **~$148/mo** (same box) | **~$112/mo** (+ 1 app spot) |
| Ollama GPU (on-demand) | g6.xlarge spot ~$0.25/hr | g2-standard-4 spot ~$0.35/hr |
| Ollama disk | ~$8/mo | ~$17/mo |

GKE's node autoscaler means you pay for agent capacity only when agents are
running. At idle, the agent pool scales to zero and the cluster runs on a
single $50/mo node.

## GCP APIs Required

```bash
gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  sqladmin.googleapis.com \
  dns.googleapis.com \
  servicenetworking.googleapis.com \
  cloudresourcemanager.googleapis.com \
  file.googleapis.com
```
