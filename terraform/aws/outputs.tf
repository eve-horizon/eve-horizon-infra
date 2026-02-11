# Eve Horizon Infrastructure - Outputs

output "ec2_public_ip" {
  description = "Public IP address of the Eve Horizon server"
  value       = module.ec2.public_ip
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (hostname)"
  value       = module.rds.endpoint
}

output "ssh_command" {
  description = "SSH command to connect to the Eve Horizon server"
  value       = "ssh ubuntu@${module.ec2.public_ip}"
}

output "database_url" {
  description = "PostgreSQL connection URL for Eve Horizon"
  value       = "postgresql://${var.db_username}:${var.db_password}@${module.rds.endpoint}/${module.rds.database_name}"
  sensitive   = true
}

output "api_url" {
  description = "Eve Horizon API URL"
  value       = "https://${var.domain}"
}

output "kubeconfig_command" {
  description = "Command to fetch kubeconfig from the k3s server"
  value       = "ssh ubuntu@${module.ec2.public_ip} 'sudo cat /etc/rancher/k3s/k3s.yaml' | sed 's/127.0.0.1/${module.ec2.public_ip}/g' > ~/.kube/eve-${var.name_prefix}.yaml"
}

output "next_steps" {
  description = "Helpful next steps after deployment"
  value       = <<-EOT
    Eve Horizon Infrastructure Deployed!

    1. SSH to the server:
       ssh ubuntu@${module.ec2.public_ip}

    2. Check k3s status:
       sudo kubectl get nodes
       sudo kubectl get pods -n eve

    3. Fetch kubeconfig:
       ${module.ec2.public_ip}  # See kubeconfig_command output

    4. Configure Eve CLI:
       export EVE_API_URL=https://${var.domain}
       eve system health

    5. View logs:
       sudo kubectl logs -n eve deployment/eve-api -f

    DNS: ${var.domain} -> ${module.ec2.public_ip}
    Database: ${module.rds.endpoint}
  EOT
}
