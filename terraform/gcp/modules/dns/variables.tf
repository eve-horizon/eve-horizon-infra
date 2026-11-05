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

variable "platform_hosts" {
  description = "Host labels under the domain that resolve to the ingress (api.<domain>, ...). Apps use *.apps.<domain>; there is no apex or *.<domain> record."
  type        = list(string)
  default     = ["api", "registry", "auth", "sso", "dashboard", "ingress"]
}

variable "legacy_wildcard_records" {
  description = "Keep the old apex and *.<domain> records. Migration aid only: they let custom domains claim platform hosts."
  type        = bool
  default     = false
}
