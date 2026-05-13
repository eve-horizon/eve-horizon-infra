output "node_group_name" {
  description = "Name of the egress-pool managed node group (visible in `aws eks list-nodegroups`)."
  value       = aws_eks_node_group.this.node_group_name
}

output "node_group_arn" {
  description = "ARN of the egress-pool managed node group."
  value       = aws_eks_node_group.this.arn
}

output "launch_template_id" {
  description = "Launch template backing the egress-pool node group."
  value       = aws_launch_template.this.id
}
