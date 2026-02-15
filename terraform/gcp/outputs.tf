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
       export EVE_API_URL=https://${var.domain}
       eve system health

    5. Deploy platform:
       ./bin/eve-infra deploy

    DNS: ${var.domain} -> ${module.gke.ingress_ip}
    Database: ${module.sql.private_ip}
  EOT
}
