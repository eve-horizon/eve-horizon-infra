# Eve Horizon Infrastructure — GCP Outputs

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

# No database_url output: it would copy the DB password into another output
# and print it with `terraform output -json`. Build DATABASE_URL from
# database_host and your tfvars (DEPLOYMENT.md, step 4).
output "database_host" {
  description = "PostgreSQL host for DATABASE_URL (Cloud SQL private IP, port 5432)"
  value       = module.sql.private_ip
}

output "cloud_sql_private_ip" {
  description = "Cloud SQL private IP address"
  value       = module.sql.private_ip
}

output "api_url" {
  description = "Eve Horizon API URL (api.<domain>, the api_host convention in config/platform.yaml)"
  value       = "https://api.${var.domain}"
}

output "ssh_command" {
  description = "SSH to GKE nodes (debugging only)"
  value       = "gcloud compute ssh --project=${var.gcp_project_id} --zone=ZONE NODE_NAME"
}

output "ollama_mig_name" {
  description = "MIG name for Ollama GPU (null if disabled)"
  value       = var.ollama_enabled ? module.ollama[0].mig_name : null
}

output "storage_service_account_email" {
  description = "Storage service account email (for Workload Identity annotation)"
  value       = module.storage.service_account_email
}

output "storage_internal_bucket" {
  description = "GCS bucket for eve-internal platform storage"
  value       = module.storage.internal_bucket_name
}

output "storage_org_bucket_prefix" {
  description = "GCS bucket prefix for per-org storage (buckets created dynamically)"
  value       = module.storage.org_bucket_prefix
}

output "next_steps" {
  description = "Helpful next steps after deployment"
  value       = <<-EOT
    Eve Horizon Infrastructure Deployed (GCP)!

    1. Configure kubectl:
       gcloud container clusters get-credentials ${module.gke.cluster_name} \
         --zone ${var.gcp_zone} --project ${var.gcp_project_id}

    2. Check cluster:
       kubectl get nodes
       kubectl get pods -n eve

    3. Run first-time setup:
       ./scripts/setup.sh

    4. Configure Eve CLI:
       export EVE_API_URL=https://api.${var.domain}
       eve system health

    5. Deploy platform:
       ./bin/eve-infra deploy

    DNS: ${var.domain} -> ${module.gke.ingress_ip}
    Database: ${module.sql.private_ip}
  EOT
}
