# DNS Module - Route53 Records
# Creates DNS records for the Eve Horizon domain:
# - A record for the apex domain (e.g., eve.example.com)
# - Wildcard A record for subdomains (e.g., *.eve.example.com)
#
# The wildcard record enables:
# - api.eve.example.com for the Eve API
# - *.orgslug-projslug-env.eve.example.com for deployed apps

# -----------------------------------------------------------------------------
# Route53 Records
# -----------------------------------------------------------------------------

# Apex domain -> EC2 Elastic IP
resource "aws_route53_record" "apex" {
  zone_id = var.route53_zone_id
  name    = var.domain
  type    = "A"
  ttl     = 300
  records = [var.ec2_public_ip]
}

# Wildcard -> EC2 Elastic IP (for subdomains: api.*, *.org-proj-env.*, etc.)
resource "aws_route53_record" "wildcard" {
  zone_id = var.route53_zone_id
  name    = "*.${var.domain}"
  type    = "A"
  ttl     = 300
  records = [var.ec2_public_ip]
}
