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

# Apex domain -> EC2 Elastic IP (k3s mode)
resource "aws_route53_record" "apex" {
  count = var.compute_model == "k3s" ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.domain
  type    = "A"
  ttl     = 300
  records = [var.ec2_public_ip]
}

# Wildcard -> EC2 Elastic IP (k3s mode)
resource "aws_route53_record" "wildcard" {
  count = var.compute_model == "k3s" ? 1 : 0

  zone_id = var.route53_zone_id
  name    = "*.${var.domain}"
  type    = "A"
  ttl     = 300
  records = [var.ec2_public_ip]
}

# Apex domain -> ingress load balancer alias (EKS mode)
resource "aws_route53_record" "apex_alias" {
  count = var.compute_model == "eks" && var.ingress_lb_dns_name != null && var.ingress_lb_zone_id != null ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.domain
  type    = "A"

  alias {
    name                   = var.ingress_lb_dns_name
    zone_id                = var.ingress_lb_zone_id
    evaluate_target_health = true
  }
}

# Wildcard -> ingress load balancer alias (EKS mode)
resource "aws_route53_record" "wildcard_alias" {
  count = var.compute_model == "eks" && var.ingress_lb_dns_name != null && var.ingress_lb_zone_id != null ? 1 : 0

  zone_id = var.route53_zone_id
  name    = "*.${var.domain}"
  type    = "A"

  alias {
    name                   = var.ingress_lb_dns_name
    zone_id                = var.ingress_lb_zone_id
    evaluate_target_health = true
  }
}
