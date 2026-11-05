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
  description = "Kubernetes service account names to bind to the platform storage service account via Workload Identity. eve-agent-runtime has its own, read-only account."
  type        = list(string)
  default     = ["eve-api", "eve-worker", "eve-orchestrator"]

  validation {
    condition     = !contains(var.workload_identity_ksas, "eve-agent-runtime")
    error_message = "eve-agent-runtime must not hold the platform storage account: agent code runs in that pod. The module binds it to its own read-only account."
  }
}

variable "workload_pool" {
  description = "Workload Identity pool for the KSA bindings. Pass module.gke.workload_pool so the bindings wait for the cluster that creates the pool. Null falls back to <project_id>.svc.id.goog with no ordering, and a first apply can then fail with \"Identity Pool does not exist\"."
  type        = string
  default     = null
}
