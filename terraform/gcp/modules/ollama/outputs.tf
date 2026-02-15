output "mig_name" {
  description = "Managed Instance Group name for Ollama"
  value       = google_compute_instance_group_manager.ollama.name
}

output "gpu_zone" {
  description = "Zone where the GPU instance runs"
  value       = local.gpu_zone
}

output "service_account_email" {
  description = "Service account email for the Ollama instance"
  value       = google_service_account.ollama.email
}
