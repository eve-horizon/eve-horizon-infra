# Offline tests for modules/storage. The Google provider is mocked, so these
# plans need no credentials and touch no project. Requires Terraform >= 1.7.
#
#   terraform -chdir=terraform/gcp init -backend=false
#   terraform -chdir=terraform/gcp test

mock_provider "google" {}

run "workload_identity_uses_the_cluster_pool" {
  command = plan

  module {
    source = "./modules/storage"
  }

  variables {
    name_prefix   = "eve-test"
    location      = "us-central1"
    project_id    = "test-project"
    workload_pool = "pool-from-cluster.svc.id.goog"
  }

  assert {
    condition = alltrue([
      for binding in google_service_account_iam_member.workload_identity :
      startswith(binding.member, "serviceAccount:pool-from-cluster.svc.id.goog[eve/")
    ])
    error_message = "Workload Identity bindings must use the pool passed in from the GKE module."
  }
}

run "workload_identity_falls_back_to_the_project_pool" {
  command = plan

  module {
    source = "./modules/storage"
  }

  variables {
    name_prefix = "eve-test"
    location    = "us-central1"
    project_id  = "test-project"
  }

  assert {
    condition     = google_service_account_iam_member.workload_identity["eve-api"].member == "serviceAccount:test-project.svc.id.goog[eve/eve-api]"
    error_message = "Without workload_pool, bindings must keep the <project>.svc.id.goog members existing installs already have."
  }
}
