# DNS Module - Outputs

output "apex_fqdn" {
  description = "Fully qualified domain name for the apex record"
  value       = aws_route53_record.apex.fqdn
}

output "wildcard_fqdn" {
  description = "Fully qualified domain name for the wildcard record"
  value       = aws_route53_record.wildcard.fqdn
}
