# Storage Module — GCS
#
# Platform object storage for org filesystem, document ingest, and internal data.
# Uses native GCS via Workload Identity — no static keys needed.
#
# Creates:
#   - Service account for storage operations
#   - Workload Identity bindings (KSA → GSA) for eve pods
#   - Internal bucket (eve-internal) for platform data
#   - IAM bindings for dynamic org bucket creation

# Service account dedicated to storage operations
resource "google_service_account" "storage" {
  account_id   = "${var.name_prefix}-eve-storage"
  display_name = "Eve storage for ${var.name_prefix}"
}

# Project-level storage admin — needed for dynamic org bucket creation
resource "google_project_iam_member" "storage_admin" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.storage.email}"
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
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/${each.value}]"
}

# Internal bucket — platform data (versioned, private, uniform access)
resource "google_storage_bucket" "eve_internal" {
  name     = "${var.name_prefix}-eve-internal"
  location = var.location
  project  = var.project_id

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }
}
