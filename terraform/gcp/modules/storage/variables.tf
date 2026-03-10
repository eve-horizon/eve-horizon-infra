variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "location" {
  description = "GCS bucket location"
  type        = string
}

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "k8s_namespace" {
  description = "Kubernetes namespace for Workload Identity bindings"
  type        = string
  default     = "eve"
}

variable "workload_identity_ksas" {
  description = "Kubernetes service account names to bind via Workload Identity"
  type        = list(string)
  default     = ["eve-api", "eve-worker", "eve-orchestrator", "eve-agent-runtime"]
}
