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

output "api_irsa_role_arn" {
  description = "IRSA role ARN for eve-api pod (S3 storage + Ollama wake)"
  value       = var.compute_model == "eks" ? aws_iam_role.api_irsa[0].arn : null
}

output "storage_internal_bucket" {
  description = "S3 bucket for eve-internal platform storage"
  value       = var.compute_model == "eks" ? aws_s3_bucket.eve_internal[0].bucket : null
}

output "storage_org_bucket_prefix" {
  description = "S3 bucket prefix for per-org storage (buckets created dynamically)"
  value       = local.storage_org_bucket_prefix
}

output "storage_app_bucket_prefix" {
  description = "S3 bucket prefix for per-app object buckets (buckets created dynamically)"
  value       = local.storage_app_bucket_prefix
}

output "app_buckets_access_key_id" {
  description = "Access key ID for shared app-bucket credentials (EKS mode only)"
  value       = var.compute_model == "eks" ? aws_iam_access_key.app_buckets[0].id : null
}

output "app_buckets_secret_access_key_sha256" {
  description = "SHA-256 fingerprint of the shared app-bucket secret access key (EKS mode only)"
  value       = var.compute_model == "eks" ? nonsensitive(sha256(aws_iam_access_key.app_buckets[0].secret)) : null
}

output "db_snapshots_bucket_name" {
  description = "S3 bucket for managed DB snapshots"
  value       = var.compute_model == "eks" ? aws_s3_bucket.db_snapshots[0].bucket : null
}

output "ses_configuration_set_name" {
  description = "Name of the SESv2 configuration set the Eve API attaches to outbound SMTP via X-SES-CONFIGURATION-SET."
  value       = module.ses_feedback.configuration_set_name
}

output "ses_feedback_topic_arn" {
  description = "SNS topic ARN receiving SES bounce/complaint/delivery/reject events. Set on the API as EVE_SES_FEEDBACK_TOPIC_ARN so the webhook handler can reject SNS messages from unexpected topics."
  value       = module.ses_feedback.topic_arn
}

output "ses_feedback_subscription_arn" {
  description = "ARN of the HTTPS subscription. Stays in PendingConfirmation until the Eve API webhook confirms it."
  value       = module.ses_feedback.subscription_arn
}

output "stable_egress_node_group_name" {
  description = "Name of the egress-pool managed node group. Use with `aws eks describe-nodegroup` to list nodes / public IPs. Null when stable egress is disabled."
  value       = local.stable_egress_eligible ? module.eks_egress_pool[0].node_group_name : null
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
