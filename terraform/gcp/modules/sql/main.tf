# Cloud SQL Module — PostgreSQL
#
# Managed PostgreSQL via Cloud SQL with private IP (VPC peering).
# Equivalent to the AWS RDS module.

resource "google_sql_database_instance" "main" {
  name             = "${var.name_prefix}-postgres"
  database_version = "POSTGRES_15"

  deletion_protection = var.deletion_protection

  settings {
    tier              = var.tier
    availability_type = "ZONAL"
    disk_autoresize   = true
    disk_size         = 20
    disk_type         = "PD_SSD"

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_id
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "03:00"
      point_in_time_recovery_enabled = true
    }

    insights_config {
      query_insights_enabled = true
    }
  }
}

resource "google_sql_database" "main" {
  name     = var.db_name
  instance = google_sql_database_instance.main.name
}

resource "google_sql_user" "main" {
  name     = var.db_username
  instance = google_sql_database_instance.main.name
  password = var.db_password
}
