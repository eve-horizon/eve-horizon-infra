output "service_account_email" {
  description = "Platform storage service account email (Workload Identity annotation for eve-api, eve-worker, eve-orchestrator)"
  value       = google_service_account.storage.email
}

output "agent_runtime_service_account_email" {
  description = "Agent runtime service account email (Workload Identity annotation for eve-agent-runtime)"
  value       = google_service_account.agent_runtime.email
}

output "internal_bucket_name" {
  description = "Name of the eve-internal GCS bucket"
  value       = google_storage_bucket.eve_internal.name
}

output "org_bucket_prefix" {
  description = "Prefix for per-org GCS buckets (created dynamically by the API)"
  value       = local.org_bucket_prefix
}

output "app_bucket_prefix" {
  description = "Prefix for per-app GCS buckets (EVE_STORAGE_APP_BUCKET_PREFIX on the worker)"
  value       = local.app_bucket_prefix
}
