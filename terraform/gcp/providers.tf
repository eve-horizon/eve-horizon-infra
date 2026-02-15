terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = local.effective_region

  default_labels = {
    project     = var.project_name
    environment = var.environment
    managed-by  = "terraform"
  }
}

provider "google-beta" {
  project = var.gcp_project_id
  region  = local.effective_region
}
