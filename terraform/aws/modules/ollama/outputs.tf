# Ollama GPU Host Module - Outputs

output "security_group_id" {
  description = "ID of the Ollama security group"
  value       = aws_security_group.ollama.id
}

output "asg_name" {
  description = "Name of the Ollama ASG (used by Eve API for on-demand wake)"
  value       = aws_autoscaling_group.ollama.name
}

output "asg_arn" {
  description = "ARN of the Ollama ASG (used for IAM policies)"
  value       = aws_autoscaling_group.ollama.arn
}

output "volume_id" {
  description = "ID of the persistent EBS volume for model storage"
  value       = aws_ebs_volume.ollama_models.id
}
