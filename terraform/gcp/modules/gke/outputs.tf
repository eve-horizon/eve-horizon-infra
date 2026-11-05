output "cluster_name" {
  description = "GKE cluster name"
  value       = google_container_cluster.main.name
}

output "network_policy_enforced" {
  description = "Whether the live cluster enforces NetworkPolicy (Dataplane V2). False for clusters created before Dataplane V2 was the default."
  value       = google_container_cluster.main.datapath_provider == "ADVANCED_DATAPATH"
}

output "cluster_endpoint" {
  description = "GKE cluster API endpoint"
  value       = google_container_cluster.main.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "GKE cluster CA certificate (base64)"
  value       = google_container_cluster.main.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "kubeconfig_command" {
  description = "Command to configure kubectl"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.main.name} --zone ${var.zone}"
}

output "ingress_ip" {
  description = "Static IP for the ingress load balancer"
  value       = google_compute_address.ingress.address
}
