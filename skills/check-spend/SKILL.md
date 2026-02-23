---
name: check-spend
description: Audit live GCP infrastructure spend against Terraform config. Itemize monthly costs by resource and flag savings opportunities.
---

# Check Spend

Audit the running cluster and report estimated monthly spend with actionable savings.

## When to Use

- Routine cost review ("what are we spending?")
- After scaling changes to verify impact
- Before/after switching environments (dev vs prod sizing)
- When looking for ways to reduce the bill

## Prerequisites

- `gcloud` CLI authenticated with project access
- `terraform` state accessible in `terraform/gcp/`
- `kubectl` access to the cluster

## The Workflow

### Step 1: Gather live resource inventory

Query GCP for every billable resource. Do not rely on Terraform config alone — compare what's declared vs what's actually running.

```bash
PROJECT="$(grep '^gcp_project_id' terraform/gcp/terraform.tfvars | awk -F'"' '{print $2}')"
REGION="$(grep '^region' terraform/gcp/terraform.tfvars | awk -F'"' '{print $2}')"

# Compute instances (node pools)
gcloud compute instances list --project="$PROJECT" \
  --format="table(name,machineType.basename(),status,scheduling.preemptible)"

# Disks
gcloud compute disks list --project="$PROJECT" \
  --format="table(name,sizeGb,type.basename(),status)"

# Cloud SQL
gcloud sql instances list --project="$PROJECT" \
  --format="table(name,settings.tier,settings.dataDiskSizeGb,settings.dataDiskType)"

# Static IPs (unused IPs cost $7.20/mo)
gcloud compute addresses list --project="$PROJECT" \
  --format="table(name,region,status,users)"

# NAT gateways
gcloud compute routers list --project="$PROJECT" \
  --format="table(name,region,network)"

# Load balancers / forwarding rules
gcloud compute forwarding-rules list --project="$PROJECT" \
  --format="table(name,region,target,IPAddress)"
```

### Step 2: Build cost estimate

Use europe-west4 pricing (adjust region if different). Produce a markdown table.

| Resource Category | Pricing Reference |
|---|---|
| e2-standard-2 (on-demand) | ~$49/mo |
| e2-standard-2 (spot) | ~$15/mo |
| e2-standard-4 (on-demand) | ~$97/mo |
| e2-standard-4 (spot) | ~$29/mo |
| pd-balanced per GB | ~$0.10/mo |
| pd-ssd per GB | ~$0.17/mo |
| Cloud SQL db-g1-small | ~$27/mo |
| Cloud SQL db-custom-2-8192 | ~$125/mo |
| Cloud NAT gateway | ~$32/mo |
| HTTP(S) Load Balancer | ~$18/mo |
| Static IP (in use) | $0 |
| Static IP (unused) | ~$7.20/mo |
| GKE zonal cluster | $0 (free tier) |
| Cloud DNS zone | ~$0.20/mo |

Output format:

```
| Resource | Spec | $/mo |
|---|---|---:|
| GKE cluster | zonal, free tier | $0 |
| Default node | e2-standard-2, on-demand | ~$49 |
| ... | ... | ... |
| **Total** | | **~$XXX** |
```

### Step 3: Check for savings

Scan for each of these opportunities and flag any that apply:

**Compute**
- Nodes running larger machine types than needed (check CPU/memory utilization if metrics available)
- On-demand nodes that could be spot (agents/apps pools should always be spot)
- Nodes running with no pods scheduled (wasted capacity)
- Default pool min > 1 when a single node suffices for dev

**Disks**
- `pd-ssd` disks that could be `pd-balanced` (fine for dev workloads)
- Oversized boot disks (50GB is plenty for dev, 30GB is minimum)
- Orphaned disks not attached to any instance

**Database**
- Cloud SQL tier larger than needed (db-g1-small for dev, db-custom for prod)
- Cloud SQL storage over-provisioned
- High availability enabled when not needed (dev doesn't need HA)

**Network**
- Unused static IPs ($7.20/mo each)
- NAT gateway costs (unavoidable with private nodes)

**Cluster**
- Regional cluster ($74.40/mo) vs zonal ($0) — zonal is fine for dev
- Agent-runtime pods pending with no nodes (expected if min=0, not a cost issue)

### Step 4: Recommend actions

For each savings opportunity, provide the specific Terraform change:

```
Saving: Switch pd-ssd to pd-balanced (~$X/mo saved)
File: terraform/gcp/modules/gke/main.tf
Change: disk_type = "pd-ssd" -> disk_type = "pd-balanced"
Apply: terraform apply
```

### Step 5: Compare against sizing profiles

Reference these profiles for quick right-sizing:

**Dev sizing (~$150/mo)**
```
compute_type            = "e2-standard-2"
default_node_min        = 1 / max = 2
agent/apps machine      = "e2-standard-2" (spot)
agent/apps min          = 0 / max = 3
compute_disk_size_gb    = 50
disk_type               = pd-balanced
database_instance_class = "db-g1-small"
```

**Staging sizing (~$300/mo)**
```
compute_type            = "e2-standard-4"
default_node_min        = 1 / max = 3
agent/apps machine      = "e2-standard-4" (spot)
agent/apps min          = 0 / max = 6
compute_disk_size_gb    = 50
disk_type               = pd-balanced
database_instance_class = "db-custom-2-8192"
```

**Production sizing (~$600/mo)**
```
compute_type            = "e2-standard-4"
default_node_min        = 2 / max = 4
agent/apps machine      = "e2-standard-4" (spot)
agent/apps min          = 1 / max = 10
compute_disk_size_gb    = 100
disk_type               = pd-ssd
database_instance_class = "db-custom-4-16384"
```

## Output

Always end with a clear summary:

1. Current monthly estimate with line items
2. Savings opportunities (if any) with dollar impact
3. Recommended sizing profile for the current use case
4. Any anomalies (orphaned resources, unused IPs, oversized instances)
