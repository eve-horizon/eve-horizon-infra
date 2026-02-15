output "connection_name" {
  description = "Cloud SQL connection name"
  value       = google_sql_database_instance.main.connection_name
}

output "private_ip" {
  description = "Cloud SQL private IP address"
  value       = google_sql_database_instance.main.private_ip_address
}

output "port" {
  description = "PostgreSQL port"
  value       = 5432
}

output "database_name" {
  description = "Database name"
  value       = google_sql_database.main.name
}
