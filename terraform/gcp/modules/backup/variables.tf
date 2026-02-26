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
