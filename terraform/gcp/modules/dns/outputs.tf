output "platform_fqdns" {
  description = "Platform host FQDNs pointing at the ingress"
  value       = [for record in google_dns_record_set.platform : record.name]
}

output "apex_fqdn" {
  description = "Legacy apex FQDN (null unless legacy_wildcard_records is set)"
  value       = one(google_dns_record_set.apex[*].name)
}

output "wildcard_fqdn" {
  description = "Legacy *.<domain> FQDN (null unless legacy_wildcard_records is set)"
  value       = one(google_dns_record_set.wildcard[*].name)
}

output "apps_wildcard_fqdn" {
  description = "Apps wildcard domain FQDN"
  value       = google_dns_record_set.apps_wildcard.name
}
