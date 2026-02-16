# DNS Module - Outputs

output "apex_fqdn" {
  description = "Fully qualified domain name for the apex record"
  value       = var.compute_model == "eks" ? try(aws_route53_record.apex_alias[0].fqdn, null) : try(aws_route53_record.apex[0].fqdn, null)
}

output "wildcard_fqdn" {
  description = "Fully qualified domain name for the wildcard record"
  value       = var.compute_model == "eks" ? try(aws_route53_record.wildcard_alias[0].fqdn, null) : try(aws_route53_record.wildcard[0].fqdn, null)
}
