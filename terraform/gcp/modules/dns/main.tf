# DNS Module — Cloud DNS Records
#
# Apex and wildcard A records pointing to the GKE ingress load balancer IP.
# Equivalent to the AWS Route53 module.

data "google_dns_managed_zone" "main" {
  name = var.dns_zone_name
}

resource "google_dns_record_set" "apex" {
  name         = "${var.domain}."
  managed_zone = data.google_dns_managed_zone.main.name
  type         = "A"
  ttl          = 300
  rrdatas      = [var.public_ip]
}

resource "google_dns_record_set" "wildcard" {
  name         = "*.${var.domain}."
  managed_zone = data.google_dns_managed_zone.main.name
  type         = "A"
  ttl          = 300
  rrdatas      = [var.public_ip]
}
