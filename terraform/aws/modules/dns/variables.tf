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
  default     = null
}

variable "compute_model" {
  description = "Compute model: k3s (single EC2) or eks (managed cluster)"
  type        = string
  validation {
    condition     = contains(["k3s", "eks"], var.compute_model)
    error_message = "compute_model must be 'k3s' or 'eks'"
  }
}

variable "ingress_lb_dns_name" {
  description = "Ingress load balancer DNS name (EKS mode)"
  type        = string
  default     = null
}

variable "ingress_lb_zone_id" {
  description = "Ingress load balancer hosted zone ID (EKS mode)"
  type        = string
  default     = null
}
