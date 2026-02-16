# Security Module - Security Groups
# Manages EC2 and RDS security groups for Eve Horizon

# -----------------------------------------------------------------------------
# EC2 Security Group
# -----------------------------------------------------------------------------
resource "aws_security_group" "ec2" {
  count = var.compute_model == "k3s" ? 1 : 0

  name        = "${var.name_prefix}-ec2-sg"
  description = "Security group for Eve Horizon EC2 instance"
  vpc_id      = var.vpc_id

  # SSH access from allowed CIDRs
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  # HTTP for Let's Encrypt certificate validation
  ingress {
    description = "HTTP for ACME/LetsEncrypt"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS for all traffic
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Kubernetes API access from allowed CIDRs
  ingress {
    description = "Kubernetes API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  # Allow all outbound traffic
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-ec2-sg"
  }
}

# -----------------------------------------------------------------------------
# RDS Security Group
# -----------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds-sg"
  description = "Security group for Eve Horizon RDS"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-rds-sg"
  }
}
