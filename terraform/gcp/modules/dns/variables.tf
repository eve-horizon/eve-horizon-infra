variable "domain" {
  description = "Eve Horizon domain name"
  type        = string
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone name"
  type        = string
}

variable "public_ip" {
  description = "Public IP for DNS records (GKE ingress load balancer)"
  type        = string
}
