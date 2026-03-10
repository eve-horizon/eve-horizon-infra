output "service_account_email" {
  description = "Storage service account email"
  value       = google_service_account.storage.email
}

output "internal_bucket_name" {
  description = "Name of the eve-internal GCS bucket"
  value       = google_storage_bucket.eve_internal.name
}

output "org_bucket_prefix" {
  description = "Prefix for per-org GCS buckets (created dynamically by the API)"
  value       = "${var.name_prefix}-eve-org"
}
