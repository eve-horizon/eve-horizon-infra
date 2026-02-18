# Ollama GPU Host Module
#
# Provisions a spot GPU instance running Ollama behind an ASG (max 1, desired 0).
# The instance starts on-demand when the Eve API sets desired=1, and auto-shuts
# down after a configurable idle timeout. Model weights persist on a dedicated
# EBS volume across stop/start cycles.

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_subnet" "selected" {
  id = var.subnet_id
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -----------------------------------------------------------------------------
# Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "ollama" {
  name        = "${var.name_prefix}-ollama-sg"
  description = "Security group for Ollama GPU host"
  vpc_id      = var.vpc_id

  # Ollama API from k3s node only
  ingress {
    description     = "Ollama API from k3s"
    from_port       = 11434
    to_port         = 11434
    protocol        = "tcp"
    security_groups = [var.k3s_security_group_id]
  }

  # SSH from allowed CIDRs
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  # All outbound (model registry pulls, AWS API calls)
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-ollama-sg"
  }
}

# -----------------------------------------------------------------------------
# Persistent EBS Volume (survives instance stop/terminate)
# -----------------------------------------------------------------------------

resource "aws_ebs_volume" "ollama_models" {
  availability_zone = data.aws_subnet.selected.availability_zone
  size              = var.volume_size
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "${var.name_prefix}-ollama-models"
  }
}

# -----------------------------------------------------------------------------
# IAM — Ollama Instance Role
# -----------------------------------------------------------------------------

resource "aws_iam_role" "ollama" {
  name = "${var.name_prefix}-ollama-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.name_prefix}-ollama-role"
  }
}

# EBS attach/describe (for reattaching the model volume on boot)
resource "aws_iam_role_policy" "ollama_ebs" {
  name = "${var.name_prefix}-ollama-ebs"
  role = aws_iam_role.ollama.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AttachVolume",
          "ec2:DescribeVolumes",
          "ec2:DescribeInstances",
        ]
        Resource = "*"
      }
    ]
  })
}

# ASG self-management (idle shutdown sets desired=0)
resource "aws_iam_role_policy" "ollama_asg_self" {
  name = "${var.name_prefix}-ollama-asg-self"
  role = aws_iam_role.ollama.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "autoscaling:UpdateAutoScalingGroup"
        Resource = aws_autoscaling_group.ollama.arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ollama" {
  name = "${var.name_prefix}-ollama-profile"
  role = aws_iam_role.ollama.name

  tags = {
    Name = "${var.name_prefix}-ollama-profile"
  }
}

# -----------------------------------------------------------------------------
# Launch Template (spot, GPU AMI, user_data)
# -----------------------------------------------------------------------------

resource "aws_launch_template" "ollama" {
  name_prefix   = "${var.name_prefix}-ollama-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.ssh_key_name

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  instance_market_options {
    market_type = "spot"
    spot_options {
      spot_instance_type = "one-time"
    }
  }

  iam_instance_profile {
    arn = aws_iam_instance_profile.ollama.arn
  }

  network_interfaces {
    security_groups             = [aws_security_group.ollama.id]
    subnet_id                   = var.subnet_id
    associate_public_ip_address = true # for model registry pulls
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    asg_name             = "${var.name_prefix}-ollama-asg"
    idle_timeout_minutes = var.idle_timeout_minutes
    region               = data.aws_region.current.name
    ollama_volume_id     = aws_ebs_volume.ollama_models.id
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.name_prefix}-ollama"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Auto Scaling Group (min=0, max=1, desired=0)
# Resting state is OFF. Eve API sets desired=1 on demand.
# Idle shutdown script sets desired=0 and halts.
# -----------------------------------------------------------------------------

resource "aws_autoscaling_group" "ollama" {
  name                = "${var.name_prefix}-ollama-asg"
  min_size            = 0
  max_size            = 1
  desired_capacity    = 0
  vpc_zone_identifier = [var.subnet_id]
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.ollama.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-ollama"
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity] # managed by API + idle shutdown
  }
}
