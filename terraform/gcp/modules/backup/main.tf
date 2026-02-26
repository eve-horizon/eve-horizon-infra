# Backup Bucket Module — GCS
#
# Nearline bucket for database dumps and filesystem snapshots.
# 30-day lifecycle keeps costs negligible.

resource "google_storage_bucket" "backups" {
  name     = "${var.name_prefix}-backups"
  location = var.location
  project  = var.project_id

  storage_class               = "NEARLINE"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }
}
