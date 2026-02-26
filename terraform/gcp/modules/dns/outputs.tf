output "apex_fqdn" {
  description = "Apex domain FQDN"
  value       = google_dns_record_set.apex.name
}

output "wildcard_fqdn" {
  description = "Wildcard domain FQDN"
  value       = google_dns_record_set.wildcard.name
}

output "apps_wildcard_fqdn" {
  description = "Apps wildcard domain FQDN"
  value       = google_dns_record_set.apps_wildcard.name
}
