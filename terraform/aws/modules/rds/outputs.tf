# RDS Module - Outputs

output "endpoint" {
  description = "RDS endpoint hostname"
  value       = aws_db_instance.main.address
}

output "port" {
  description = "RDS port"
  value       = aws_db_instance.main.port
}

output "database_name" {
  description = "The database name"
  value       = aws_db_instance.main.db_name
}

output "parameter_group_name" {
  description = "Custom DB parameter group name when preload extensions are enabled"
  value       = try(aws_db_parameter_group.main[0].name, null)
}
