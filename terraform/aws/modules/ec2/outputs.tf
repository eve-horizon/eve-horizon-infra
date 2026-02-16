# EC2 Module - Outputs

output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.main.id
}

output "public_ip" {
  description = "Public IP address (Elastic IP) of the EC2 instance"
  value       = aws_eip.main.public_ip
}

output "private_ip" {
  description = "Private IP address of the EC2 instance"
  value       = aws_instance.main.private_ip
}

output "key_pair_name" {
  description = "Name of the SSH key pair (for use by other modules)"
  value       = var.ssh_key_name
}
