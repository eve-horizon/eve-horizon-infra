# DNS Module - Input Variables

variable "domain" {
  description = "Domain name for Eve Horizon (e.g., eve.example.com)"
  type        = string
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID"
  type        = string
}

variable "ec2_public_ip" {
  description = "Public IP address to point DNS records at"
  type        = string
}
