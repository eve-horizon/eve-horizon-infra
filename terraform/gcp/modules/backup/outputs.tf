output "bucket_name" {
  description = "Name of the backup GCS bucket"
  value       = google_storage_bucket.backups.name
}
