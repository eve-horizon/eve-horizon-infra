# EC2 Module - Eve Horizon Server Instance
# Single-node k3s server with Ubuntu 22.04

# -----------------------------------------------------------------------------
# SSH Key Pair
# -----------------------------------------------------------------------------
resource "aws_key_pair" "main" {
  key_name   = "${var.name_prefix}-key"
  public_key = var.ssh_public_key

  tags = {
    Name = "${var.name_prefix}-key"
  }
}

# -----------------------------------------------------------------------------
# Ubuntu AMI Data Source
# -----------------------------------------------------------------------------
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
# EC2 Instance
# -----------------------------------------------------------------------------
resource "aws_instance" "main" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
  key_name               = aws_key_pair.main.key_name

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    database_url = var.database_url
    domain       = var.domain
  })

  tags = {
    Name = "${var.name_prefix}-server"
  }

  lifecycle {
    ignore_changes = [ami] # Don't replace on AMI updates
  }
}

# -----------------------------------------------------------------------------
# Elastic IP
# -----------------------------------------------------------------------------
resource "aws_eip" "main" {
  instance = aws_instance.main.id
  domain   = "vpc"

  tags = {
    Name = "${var.name_prefix}-eip"
  }
}
