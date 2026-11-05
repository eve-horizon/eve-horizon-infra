# Storage Module — GCS
#
# Platform object storage for org filesystem, document ingest, and internal data.
# Uses native GCS via Workload Identity — no static keys needed.
#
# Creates:
#   - Platform storage service account (API, worker, orchestrator)
#   - Agent runtime service account (read-only, org buckets only)
#   - Bucket-name-scoped IAM for both, through custom roles
#   - Workload Identity bindings (KSA → GSA) for eve pods
#   - Internal bucket (eve-internal) for platform data
#
# Every bucket Eve uses must be named "<name_prefix>-eve-*"; the IAM below
# grants nothing outside that prefix. See README.md for the bucket names, the
# access model, and why Terraform state must not live in this project.

locals {
  # The pool only exists once the GKE cluster does. Taking it from the GKE
  # module (var.workload_pool) orders these bindings after the cluster; the
  # fallback keeps older root modules working but has no such ordering.
  workload_pool = coalesce(var.workload_pool, "${var.project_id}.svc.id.goog")

  bucket_prefix     = "${var.name_prefix}-eve"     # every Eve bucket
  org_bucket_prefix = "${local.bucket_prefix}-org" # EVE_STORAGE_ORG_BUCKET_PREFIX
  app_bucket_prefix = "${local.bucket_prefix}-app" # EVE_STORAGE_APP_BUCKET_PREFIX

  # Custom role IDs are unique per project, so they carry the instance prefix.
  role_id_prefix = replace(var.name_prefix, "-", "_")

  agent_runtime_ksa = "eve-agent-runtime"
}

# -----------------------------------------------------------------------------
# Platform storage account — API, worker, orchestrator
# -----------------------------------------------------------------------------

# Service account dedicated to storage operations
resource "google_service_account" "storage" {
  account_id   = "${var.name_prefix}-eve-storage"
  display_name = "Eve storage for ${var.name_prefix}"
}

# Code that runs in these pods (pipeline scripts in the worker, for example)
# can use this identity, so it gets the storage permissions of
# roles/storage.admin without the setIamPolicy ones, and only on Eve's own
# buckets. Other buckets in the project, such as backups or Terraform state,
# are out of reach, and no one can be granted lasting access to Eve's buckets.
data "google_iam_role" "storage_admin" {
  name = "roles/storage.admin"
}

resource "google_project_iam_custom_role" "storage_operator" {
  project     = var.project_id
  role_id     = "${local.role_id_prefix}_eveStorageOperator"
  title       = "Eve storage operator (${var.name_prefix})"
  description = "Storage permissions of roles/storage.admin without setIamPolicy"
  permissions = sort([
    for permission in data.google_iam_role.storage_admin.included_permissions : permission
    if startswith(permission, "storage.") && !endswith(permission, ".setIamPolicy")
  ])
}

# Replaces the earlier project-wide roles/storage.admin grant. The new binding
# is created before the old one is removed, so storage access does not lapse
# during the apply.
moved {
  from = google_project_iam_member.storage_admin
  to   = google_project_iam_member.storage_operator
}

resource "google_project_iam_member" "storage_operator" {
  project = var.project_id
  role    = google_project_iam_custom_role.storage_operator.id
  member  = "serviceAccount:${google_service_account.storage.email}"

  condition {
    title       = "eve-buckets-only"
    description = "Only buckets named ${local.bucket_prefix}-*"
    expression  = "resource.name.startsWith(\"projects/_/buckets/${local.bucket_prefix}-\")"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Bucket creation is checked on the project, not on the new bucket's name, so
# it cannot carry the condition above. It grants no access to any bucket,
# including the ones it creates; the operator role covers Eve's.
resource "google_project_iam_custom_role" "bucket_creator" {
  project     = var.project_id
  role_id     = "${local.role_id_prefix}_eveBucketCreator"
  title       = "Eve bucket creator (${var.name_prefix})"
  description = "Create Eve org and app buckets"
  permissions = ["storage.buckets.create"]
}

resource "google_project_iam_member" "bucket_creator" {
  project = var.project_id
  role    = google_project_iam_custom_role.bucket_creator.id
  member  = "serviceAccount:${google_service_account.storage.email}"
}

# Eve edits bucket IAM only to make `visibility: public` app buckets readable,
# so setIamPolicy is limited to the app-bucket prefix. The worker must set
# EVE_STORAGE_APP_BUCKET_PREFIX to app_bucket_prefix; without it app buckets
# are named after the org prefix and this grant does not match them.
resource "google_project_iam_custom_role" "app_bucket_publisher" {
  project     = var.project_id
  role_id     = "${local.role_id_prefix}_eveAppBucketPublisher"
  title       = "Eve app bucket publisher (${var.name_prefix})"
  description = "Read and set bucket IAM, used to make public app buckets readable"
  permissions = ["storage.buckets.getIamPolicy", "storage.buckets.setIamPolicy"]
}

resource "google_project_iam_member" "app_bucket_publisher" {
  project = var.project_id
  role    = google_project_iam_custom_role.app_bucket_publisher.id
  member  = "serviceAccount:${google_service_account.storage.email}"

  condition {
    title       = "eve-app-buckets-only"
    description = "Only buckets named ${local.app_bucket_prefix}-*"
    expression  = "resource.name.startsWith(\"projects/_/buckets/${local.app_bucket_prefix}-\")"
  }
}

# Self-signBlob — needed for generating signed/presigned URLs via GCS
resource "google_service_account_iam_member" "storage_token_creator" {
  service_account_id = google_service_account.storage.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.storage.email}"
}

# Workload Identity bindings — let eve KSAs act as the storage GSA
resource "google_service_account_iam_member" "workload_identity" {
  for_each = toset(var.workload_identity_ksas)

  service_account_id = google_service_account.storage.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.workload_pool}[${var.k8s_namespace}/${each.value}]"
}

# -----------------------------------------------------------------------------
# Agent runtime account
# -----------------------------------------------------------------------------

# The agent runtime reads ingested files (ingest/...) from org buckets and
# nothing else from GCS; chat attachments reach it through the API. Agent code
# runs in the same pod and can take this identity's token, so it gets object
# read on org buckets and nothing more: no internal or app buckets, no writes,
# no bucket or IAM changes.
resource "google_service_account" "agent_runtime" {
  account_id   = "${var.name_prefix}-eve-agents"
  display_name = "Eve agent runtime for ${var.name_prefix}"
}

resource "google_project_iam_member" "agent_runtime_org_objects" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.agent_runtime.email}"

  condition {
    title       = "eve-org-buckets-read-only"
    description = "Only objects in buckets named ${local.org_bucket_prefix}-*"
    expression  = "resource.name.startsWith(\"projects/_/buckets/${local.org_bucket_prefix}-\")"
  }
}

resource "google_service_account_iam_member" "agent_runtime_workload_identity" {
  service_account_id = google_service_account.agent_runtime.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.workload_pool}[${var.k8s_namespace}/${local.agent_runtime_ksa}]"
}

# -----------------------------------------------------------------------------
# Buckets
# -----------------------------------------------------------------------------

# Internal bucket — platform data (versioned, private, uniform access)
resource "google_storage_bucket" "eve_internal" {
  name     = "${local.bucket_prefix}-internal"
  location = var.location
  project  = var.project_id

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }
}
