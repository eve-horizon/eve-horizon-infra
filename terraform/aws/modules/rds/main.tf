# RDS Module - PostgreSQL Database Instance
# Creates a managed PostgreSQL database in private subnets

locals {
  enabled_preload_extensions = distinct(var.enabled_preload_extensions)
  preload_parameter_enabled  = length(local.enabled_preload_extensions) > 0
}

# -----------------------------------------------------------------------------
# DB Subnet Group
# Places RDS in private subnets for security
# -----------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name        = "${var.name_prefix}-db-subnet"
  description = "Database subnet group for ${var.name_prefix}"
  subnet_ids  = var.subnet_ids

  tags = {
    Name = "${var.name_prefix}-db-subnet-group"
  }
}

# -----------------------------------------------------------------------------
# DB Parameter Group
# Enables provider-gated PostgreSQL extensions that require preload.
# Static shared_preload_libraries changes require a DB reboot before use.
# -----------------------------------------------------------------------------
resource "aws_db_parameter_group" "main" {
  count = local.preload_parameter_enabled ? 1 : 0

  name        = "${var.name_prefix}-postgres-params"
  family      = "postgres15"
  description = "PostgreSQL parameters for ${var.name_prefix}"

  parameter {
    name         = "shared_preload_libraries"
    value        = join(",", local.enabled_preload_extensions)
    apply_method = "pending-reboot"
  }

  tags = {
    Name = "${var.name_prefix}-postgres-params"
  }
}

# -----------------------------------------------------------------------------
# RDS PostgreSQL Instance
# Managed PostgreSQL 15 with encryption and automated backups
# -----------------------------------------------------------------------------
resource "aws_db_instance" "main" {
  identifier = "${var.name_prefix}-postgres"

  # Engine configuration
  engine         = "postgres"
  engine_version = "15"

  # Instance sizing
  instance_class = var.db_instance_class

  # Storage configuration
  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  # Database configuration
  db_name  = var.db_name
  username = var.db_username
  password = var.db_password
  port     = 5432

  # Network configuration
  db_subnet_group_name   = aws_db_subnet_group.main.name
  parameter_group_name   = local.preload_parameter_enabled ? aws_db_parameter_group.main[0].name : null
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false

  # Backup configuration
  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  # Protection settings (set deletion_protection = true for production)
  skip_final_snapshot      = !var.deletion_protection
  delete_automated_backups = !var.deletion_protection
  deletion_protection      = var.deletion_protection

  # Apply changes immediately (don't defer to maintenance window)
  apply_immediately = true

  # Performance monitoring
  performance_insights_enabled = true

  tags = {
    Name = "${var.name_prefix}-postgres"
  }
}
