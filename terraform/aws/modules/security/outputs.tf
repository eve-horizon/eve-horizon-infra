# Security Module - Outputs

output "ec2_security_group_id" {
  description = "ID of the EC2 security group"
  value       = length(aws_security_group.ec2) > 0 ? aws_security_group.ec2[0].id : null
}

output "rds_security_group_id" {
  description = "ID of the RDS security group"
  value       = aws_security_group.rds.id
}
