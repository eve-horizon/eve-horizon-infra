# Eve Horizon Infrastructure - AWS Outputs

output "ec2_public_ip" {
  description = "Public IP address of the Eve Horizon server (k3s mode only)"
  value       = var.compute_model == "k3s" ? module.ec2[0].public_ip : null
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (hostname)"
  value       = module.rds.endpoint
}

output "ssh_command" {
  description = "SSH command to connect to the Eve Horizon server (k3s mode only)"
  value       = var.compute_model == "k3s" ? "ssh ubuntu@${module.ec2[0].public_ip}" : null
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

output "cluster_name" {
  description = "EKS cluster name (EKS mode only)"
  value       = var.compute_model == "eks" ? module.eks[0].cluster_name : null
}

output "cluster_endpoint" {
  description = "EKS API endpoint (EKS mode only)"
  value       = var.compute_model == "eks" ? module.eks[0].cluster_endpoint : null
}

output "kubeconfig_command" {
  description = "Command to configure kubectl"
  value = var.compute_model == "eks" ? (
    "aws eks update-kubeconfig --name ${module.eks[0].cluster_name} --region ${local.effective_region}"
    ) : (
    "ssh ubuntu@${module.ec2[0].public_ip} 'sudo cat /etc/rancher/k3s/k3s.yaml' | sed 's/127.0.0.1/${module.ec2[0].public_ip}/g' > ~/.kube/eve-${var.name_prefix}.yaml"
  )
}

output "registry_bucket_name" {
  description = "S3 bucket backing the Eve registry (EKS mode only)"
  value       = var.compute_model == "eks" ? aws_s3_bucket.registry[0].bucket : null
}

output "registry_irsa_role_arn" {
  description = "IRSA role ARN for registry pods (EKS mode only)"
  value       = var.compute_model == "eks" ? aws_iam_role.registry_irsa[0].arn : null
}

output "cluster_autoscaler_irsa_role_arn" {
  description = "IRSA role ARN for Cluster Autoscaler (EKS mode only)"
  value       = var.compute_model == "eks" ? module.eks[0].cluster_autoscaler_irsa_role_arn : null
}

output "ollama_asg_name" {
  description = "ASG name for the Ollama GPU host (set as EVE_OLLAMA_ASG_NAME)"
  value       = var.ollama_enabled ? module.ollama[0].asg_name : null
}

output "next_steps" {
  description = "Helpful next steps after deployment"
  value = var.compute_model == "eks" ? (
    <<-EOT
    Eve Horizon Infrastructure Deployed (EKS)!

    1. Configure kubectl:
       aws eks update-kubeconfig --name ${module.eks[0].cluster_name} --region ${local.effective_region}

    2. Install cluster prerequisites:
       ./scripts/setup.sh

    3. Deploy platform:
       ./bin/eve-infra deploy

    4. Verify workloads:
       kubectl get nodes
       kubectl get pods -n eve

    DNS: ${var.domain} -> ingress load balancer alias (set ingress_lb_dns_name + ingress_lb_zone_id)
    Database: ${module.rds.endpoint}
  EOT
    ) : (
    <<-EOT
    Eve Horizon Infrastructure Deployed (k3s)!

    1. SSH to the server:
       ssh ubuntu@${module.ec2[0].public_ip}

    2. Check k3s status:
       sudo kubectl get nodes
       sudo kubectl get pods -n eve

    3. Fetch kubeconfig:
       ssh ubuntu@${module.ec2[0].public_ip} 'sudo cat /etc/rancher/k3s/k3s.yaml' | sed 's/127.0.0.1/${module.ec2[0].public_ip}/g' > ~/.kube/eve-${var.name_prefix}.yaml

    4. Deploy platform:
       ./scripts/setup.sh
       ./bin/eve-infra deploy

    DNS: ${var.domain} -> ${module.ec2[0].public_ip}
    Database: ${module.rds.endpoint}
  EOT
  )
}
