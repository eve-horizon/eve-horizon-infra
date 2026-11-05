# Offline tests for modules/storage. The Google provider is mocked, so these
# plans need no credentials and touch no project. Requires Terraform >= 1.7.
#
#   terraform -chdir=terraform/gcp init -backend=false
#   terraform -chdir=terraform/gcp test

mock_provider "google" {
  # A representative slice of roles/storage.admin, including the IAM-editing
  # and non-storage permissions the operator role must leave out.
  mock_data "google_iam_role" {
    defaults = {
      included_permissions = [
        "resourcemanager.projects.get",
        "resourcemanager.projects.list",
        "storage.buckets.create",
        "storage.buckets.delete",
        "storage.buckets.get",
        "storage.buckets.getIamPolicy",
        "storage.buckets.setIamPolicy",
        "storage.buckets.update",
        "storage.managedFolders.getIamPolicy",
        "storage.managedFolders.setIamPolicy",
        "storage.multipartUploads.create",
        "storage.objects.create",
        "storage.objects.delete",
        "storage.objects.get",
        "storage.objects.getIamPolicy",
        "storage.objects.list",
        "storage.objects.setIamPolicy",
        "storage.objects.update",
      ]
    }
  }
}

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

run "platform_account_is_limited_to_eve_buckets" {
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
    condition = alltrue([
      for permission in google_project_iam_custom_role.storage_operator.permissions :
      startswith(permission, "storage.") && !endswith(permission, ".setIamPolicy")
    ])
    error_message = "The operator role must hold only storage permissions and no setIamPolicy."
  }

  assert {
    condition = alltrue([
      for permission in ["storage.objects.get", "storage.objects.create", "storage.buckets.update", "storage.buckets.getIamPolicy"] :
      contains(google_project_iam_custom_role.storage_operator.permissions, permission)
    ])
    error_message = "The operator role must keep the object and bucket permissions Eve uses."
  }

  assert {
    condition     = google_project_iam_member.storage_operator.condition[0].expression == "resource.name.startsWith(\"projects/_/buckets/eve-test-eve-\")"
    error_message = "The operator grant must be conditioned on the <name_prefix>-eve- bucket prefix."
  }

  assert {
    condition     = google_project_iam_custom_role.bucket_creator.permissions == toset(["storage.buckets.create"]) && length(google_project_iam_member.bucket_creator.condition) == 0
    error_message = "The unconditioned project grant must carry storage.buckets.create and nothing else."
  }

  assert {
    condition     = google_project_iam_custom_role.app_bucket_publisher.permissions == toset(["storage.buckets.getIamPolicy", "storage.buckets.setIamPolicy"])
    error_message = "The publisher role must carry only bucket IAM read and write."
  }

  assert {
    condition     = google_project_iam_member.app_bucket_publisher.condition[0].expression == "resource.name.startsWith(\"projects/_/buckets/eve-test-eve-app-\")"
    error_message = "Bucket IAM edits must be limited to app buckets."
  }

  assert {
    condition     = google_project_iam_custom_role.storage_operator.role_id == "eve_test_eveStorageOperator"
    error_message = "Custom role IDs must carry the instance prefix so instances sharing a project do not collide."
  }

  assert {
    condition     = output.app_bucket_prefix == "eve-test-eve-app" && output.org_bucket_prefix == "eve-test-eve-org"
    error_message = "App and org buckets must have distinct prefixes under <name_prefix>-eve."
  }
}

run "agent_runtime_has_its_own_read_only_account" {
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
    condition     = !contains(keys(google_service_account_iam_member.workload_identity), "eve-agent-runtime")
    error_message = "eve-agent-runtime must not be bound to the platform storage account."
  }

  assert {
    condition     = google_service_account_iam_member.agent_runtime_workload_identity.member == "serviceAccount:pool-from-cluster.svc.id.goog[eve/eve-agent-runtime]"
    error_message = "eve-agent-runtime must be bound to its own account through the cluster's pool."
  }

  assert {
    condition     = google_service_account.agent_runtime.account_id == "eve-test-eve-agents"
    error_message = "The agent runtime account must be <name_prefix>-eve-agents, which the GCP overlay annotates."
  }

  assert {
    condition     = google_project_iam_member.agent_runtime_org_objects.role == "roles/storage.objectViewer"
    error_message = "The agent runtime must only read objects."
  }

  assert {
    condition     = google_project_iam_member.agent_runtime_org_objects.condition[0].expression == "resource.name.startsWith(\"projects/_/buckets/eve-test-eve-org-\")"
    error_message = "The agent runtime must only reach org buckets."
  }
}

run "agent_runtime_cannot_rejoin_the_platform_account" {
  command = plan

  module {
    source = "./modules/storage"
  }

  variables {
    name_prefix            = "eve-test"
    location               = "us-central1"
    project_id             = "test-project"
    workload_identity_ksas = ["eve-api", "eve-worker", "eve-orchestrator", "eve-agent-runtime"]
  }

  expect_failures = [
    var.workload_identity_ksas,
  ]
}
