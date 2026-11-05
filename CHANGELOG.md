# Changelog

All notable changes to the `eve-horizon-infra` template.

Downstream repos: consult this during `upstream-sync` operations.
Each entry includes **Sync impact** to guide what downstream agents need to do.

---

## [2026-11-05]

### fix: give GCP managed-database snapshots a bucket inside the Eve prefix

The GCP overlay never set `EVE_DB_SNAPSHOT_BUCKET`, so Eve wrote managed-DB
snapshots to `eve-local-db-snapshots`, which nothing creates and which sits
outside the scoped storage grants. The storage module now creates
`<name_prefix>-eve-db-snapshots` (private, not versioned), and the GCP api and
orchestrator point `EVE_DB_SNAPSHOT_BUCKET` at it. The agent runtime cannot
read it.

- **Scope:** `terraform/gcp/modules/storage/`, `terraform/gcp/outputs.tf`,
  `k8s/overlays/gcp/api-deployment-patch.yaml`,
  `k8s/overlays/gcp/orchestrator-deployment-patch.yaml`,
  `scripts/validate-template.sh`, `terraform/gcp/tests/storage.tftest.hcl`
- **Sync impact:**
  - `terraform/gcp/modules/storage/` — auto-sync safe (adds one empty bucket)
  - `k8s/overlays/gcp/{api,orchestrator}-deployment-patch.yaml` — manual
    merge (one env var each; apply Terraform first so the bucket exists).
    If you already set `EVE_DB_SNAPSHOT_BUCKET` or `EVE_DEPLOYMENT_ID` through
    `secrets.env`, keep a bucket name under `<name_prefix>-eve-` or move the
    existing snapshots across.
  - `terraform/gcp/outputs.tf` — manual merge (adds `storage_db_snapshot_bucket`)

### fix: scope GCP storage IAM to Eve's buckets and give agent-runtime its own account

The GCP storage service account held `roles/storage.admin` on the whole
project, including `setIamPolicy` on every bucket, and `eve-agent-runtime`
was bound to it through Workload Identity. Code running in those pods (agent
code, pipeline scripts) could read or change any bucket in the project,
including backups or Terraform state, and grant outsiders lasting access.

- The platform account (`eve-api`, `eve-worker`, `eve-orchestrator`) now holds
  a custom role with the storage permissions of `roles/storage.admin` minus
  `*.setIamPolicy`, conditioned on `<name_prefix>-eve-*` buckets;
  `storage.buckets.create` on the project; and bucket IAM read/write on
  `<name_prefix>-eve-app-*` only, which Eve needs to make public app buckets
  readable.
- `eve-agent-runtime` gets a new account, `<name_prefix>-eve-agents`, with
  `roles/storage.objectViewer` on `<name_prefix>-eve-org-*` only. The agent
  runtime reads ingested files from org buckets and nothing else from GCS.
  The module refuses `eve-agent-runtime` in `workload_identity_ksas`.
- The GCP worker sets `EVE_STORAGE_APP_BUCKET_PREFIX=INSTANCE_PREFIX-eve-app`,
  so app buckets no longer share the org-bucket prefix.
- `terraform/gcp/modules/storage/README.md` documents the bucket names, the
  access model, the upgrade order, why Terraform state must stay out of the
  instance project, and why the template does not provision `shared`
  app-storage keys on GCP.

- **Scope:** `terraform/gcp/modules/storage/`, `terraform/gcp/outputs.tf`,
  `terraform/gcp/backend.tf.example`, `terraform/gcp/tests/storage.tftest.hcl`,
  `k8s/overlays/gcp/storage-workload-identity.yaml`,
  `k8s/overlays/gcp/worker-deployment-patch.yaml`,
  `scripts/validate-template.sh`
- **Sync impact:**
  - `terraform/gcp/modules/storage/` — **action required** (auto-synced, but
    must ship together with the overlay change below). On apply: creates the
    `<name_prefix>-eve-agents` account and three custom roles; replaces the
    project-wide `roles/storage.admin` grant (a `moved` block makes it
    create-before-destroy); deletes the `eve-agent-runtime` binding on the
    platform account. No service account is renamed and no bucket is touched.
    Before applying, confirm every bucket setting in your GCP overlay starts
    with `<name_prefix>-eve-`; any other bucket loses access. Follow the
    upgrade order in the module README.
  - `k8s/overlays/gcp/storage-workload-identity.yaml` — **action required**
    (manual merge): annotate `eve-agent-runtime` with
    `<name_prefix>-eve-agents@<project>.iam.gserviceaccount.com`. Deploy right
    after `terraform apply` and restart the agent runtime; in between, agent
    jobs cannot fetch `ingest://` resources.
  - `k8s/overlays/gcp/worker-deployment-patch.yaml` — manual merge. Safe as
    is unless apps already have object-store buckets (only possible if you
    configured `EVE_APP_STORAGE_*` yourself): the new prefix renames app
    buckets, so the next deploy creates new, empty ones. Copy the data first,
    or keep app buckets on the org prefix and accept that public app buckets
    then fail to publish.
  - `terraform/gcp/outputs.tf` — manual merge (adds
    `storage_app_bucket_prefix` and
    `storage_agent_runtime_service_account_email`)
  - `terraform/gcp/backend.tf.example`, `scripts/validate-template.sh`,
    `terraform/gcp/tests/` — auto-sync safe

### fix: order GCP Workload Identity bindings after the GKE cluster

The storage module's Workload Identity bindings built the pool name from the
project ID and had no dependency on the cluster that creates the pool, so a
first `terraform apply` could fail with `Identity Pool does not exist` and
need a second run. The GKE module now exports `workload_pool`, and the root
module passes it to the storage module, which orders the bindings after the
cluster. The member strings are unchanged.

- **Scope:** `terraform/gcp/modules/gke/outputs.tf`,
  `terraform/gcp/modules/storage/`, `terraform/gcp/main.tf`,
  `terraform/gcp/tests/storage.tftest.hcl`, `.github/workflows/template-ci.yml`
- **Sync impact:**
  - `terraform/gcp/modules/` — auto-sync safe (new `workload_pool` output and
    optional input; without the input the module behaves as before, and
    `terraform plan` shows no change for an existing install)
  - `terraform/gcp/main.tf` — manual merge (pass
    `workload_pool = module.gke.workload_pool` to `module "storage"`; plan
    shows no change)
  - `terraform/gcp/tests/`, `.github/workflows/template-ci.yml` — auto-sync
    safe (offline `terraform test` with a mocked Google provider; needs
    Terraform >= 1.7)

## [2026-08-25]

### fix: preserve migration safety and complete auth bootstrap overlays

- **Scope:** `bin/eve-infra`, `k8s/base/supabase-auth-deployment.yaml`,
  `k8s/overlays/{aws-eks,gcp}/auth-bootstrap-job.yaml`,
  `scripts/validate-template.sh`, `skills/eve-template-backport-sync/`
- **Sync impact:**
  - `bin/eve-infra`, auth URL paths, and auth bootstrap jobs — auto-sync safe
    (deploy runs migrations before rollout, migration commands apply only the
    one-shot Job, migration status is inspectable, and every supported overlay
    has the auth bootstrap file consumed by the deploy workflow)
  - `scripts/validate-template.sh` — template-only CI assertion
  - `skills/eve-template-backport-sync/` — auto-sync safe; restores the
    mandatory instance-value scrub before public-template staging

### ci: validate the generic infrastructure template

- **Scope:** `.github/workflows/`, `scripts/validate-template.sh`,
  `.upstream-sync.example.json`, `CLAUDE.md`, `skills/upstream-sync/`,
  `skills/manual-test-scenarios/`, `terraform/aws-backend/outputs.tf`,
  `terraform/{aws,gcp}/.terraform.lock.hcl`
- **Sync impact:**
  - `.github/workflows/`, `scripts/validate-template.sh` — auto-sync safe (the
    canonical template skips instance-only deploy, health, and release checks;
    downstream copies continue to run them, while template CI renders all
    overlays and validates coordinated upgrades and Terraform)
  - `.upstream-sync.example.json`, `CLAUDE.md`, `skills/upstream-sync/` — manual
    merge (generic skills remain auto-sync; instance-owned manual test guidance
    is explicitly `never`)
  - `skills/manual-test-scenarios/` — remove from the public template only;
    downstream instances must retain their private deployment-specific copy
  - `terraform/aws-backend/outputs.tf` — auto-sync safe (removes duplicate
    output declarations; the documented outputs remain in `main.tf`)
  - `terraform/{aws,gcp}/.terraform.lock.hcl` — auto-sync safe (records every
    provider required by credential-free validation)

## [2026-08-24]

### fix: separate source publication from instance deployment

- **Scope:** `.github/workflows/deploy.yml`, `bin/eve-infra`, `k8s/overlays/aws/`, `k8s/overlays/aws-eks/`, `k8s/overlays/gcp/`, `UPGRADE.md`, `skills/eve-horizon-release/SKILL.md`, `skills/eve-infra-ops/SKILL.md`, `skills/redeploy-if-necessary/SKILL.md`, `CLAUDE.md`
- **Sync impact:**
  - `.github/workflows/deploy.yml` — manual merge (removes the obsolete `repository_dispatch` trigger and payload version path; preserves deploy tags and manual dispatch)
  - `bin/eve-infra`, service and runner-image overlay patches — auto-sync safe (add missing dashboard/service overrides, move AWS-EKS from GHCR to public ECR, make GCP registry deletion Kustomize-v5-safe, upgrade all seven services, and use the published `worker` image for runner pods instead of legacy `worker-full`)
  - `UPGRADE.md`, `skills/`, `CLAUDE.md` — auto-sync safe (documents the public source's publish-only release model, ECR-backed version discovery, and instance-owner rollout boundary)

## [2026-02-14]

### feat: add upstream sync system
- **Scope:** `skills/upstream-sync/`, `.upstream-sync.example.json`, `CHANGELOG.md`, `bin/eve-infra`, `CLAUDE.md`
- **Sync impact:**
  - `skills/upstream-sync/SKILL.md` — auto-sync safe (new file)
  - `.upstream-sync.example.json` — auto-sync safe (new file, template only)
  - `CHANGELOG.md` — auto-sync safe (new file, template history)
  - `bin/eve-infra` — auto-sync safe (new `sync` subcommand, no breaking changes)
  - `CLAUDE.md` — manual merge (new section added; preserve downstream customizations)

### feat: add optional Ollama GPU module for on-demand inference
- **Scope:** `terraform/aws/modules/ollama/`, `terraform/aws/main.tf`, `terraform/aws/variables.tf`, `terraform/aws/outputs.tf`, `terraform/aws/terraform.tfvars.example`, `config/platform.yaml`, `config/secrets.env.example`, `DEPLOYMENT.md`
- **Sync impact:**
  - `terraform/aws/modules/ollama/` — auto-sync safe (new module)
  - `terraform/aws/main.tf` — manual merge (new module block added; keep your existing variable values)
  - `terraform/aws/variables.tf` — manual merge (new `ollama_*` variables added with defaults)
  - `terraform/aws/outputs.tf` — manual merge (new Ollama outputs added)
  - `terraform/aws/terraform.tfvars.example` — informational (review new variables, add to your tfvars if enabling Ollama)
  - `config/platform.yaml` — never sync (new `ollama` section; add manually if desired)
  - `config/secrets.env.example` — informational (new `EVE_OLLAMA_BASE_URL` key)
  - `DEPLOYMENT.md` — manual merge (new Ollama deployment section added)
  - `terraform/aws/modules/ec2/` — auto-sync safe (IAM profile variable added)

### docs: plan for first-class Ollama GPU module
- **Scope:** `docs/plans/ollama-gpu-module.md`
- **Sync impact:** informational only (planning document, no operational effect)

## [2026-02-11]

### feat: enable managed Postgres reconciler in AWS overlay
- **Scope:** `k8s/overlays/aws/orchestrator-deployment-patch.yaml`
- **Sync impact:** manual merge (adds `MANAGED_POSTGRES=true` env var to orchestrator; review if you've customized this patch)

### fix: correct skills directory structure and manifest
- **Scope:** `.gitignore`, `skills.txt`, `skills/eve-infra-ops/SKILL.md`, `CLAUDE.md`
- **Sync impact:**
  - `skills/`, `skills.txt` — auto-sync safe
  - `.gitignore` — manual merge (new ignore patterns for installed skills)
  - `CLAUDE.md` — manual merge (skills section updated)

### feat: add agent skills, CLAUDE.md, and local kubeconfig support
- **Scope:** `skills/eve-infra-ops/SKILL.md`, `CLAUDE.md`, `bin/eve-infra`, `.gitignore`
- **Sync impact:**
  - `skills/eve-infra-ops/SKILL.md` — auto-sync safe (new file)
  - `CLAUDE.md` — manual merge (new file; may have downstream customizations)
  - `bin/eve-infra` — auto-sync safe (kubeconfig resolution added)
  - `.gitignore` — manual merge (new entries)

### fix: db-migrate-job kustomize handling
- **Scope:** `k8s/overlays/aws/kustomization.yaml`, `k8s/overlays/aws/db-migrate-job-patch.yaml`
- **Sync impact:** auto-sync safe (migration job excluded from kustomize build to prevent apply conflicts; the CLI handles it separately)

### docs: add README, DEPLOYMENT, and UPGRADE guides
- **Scope:** `README.md`, `DEPLOYMENT.md`, `UPGRADE.md`
- **Sync impact:** manual merge (if you've customized these docs, merge upstream additions; otherwise accept)

### feat: add operational CLI, deploy workflows, and cluster setup script
- **Scope:** `bin/eve-infra`, `scripts/setup.sh`, `.github/workflows/deploy.yml`, `.github/workflows/health-check.yml`, `.github/workflows/upgrade-check.yml`
- **Sync impact:**
  - `bin/eve-infra` — auto-sync safe
  - `scripts/` — auto-sync safe
  - `.github/workflows/` — auto-sync safe

### feat: add platform.yaml config schema and secrets.env.example
- **Scope:** `config/platform.yaml`, `config/secrets.env.example`
- **Sync impact:**
  - `config/platform.yaml` — never sync (instance-specific)
  - `config/secrets.env.example` — informational (review for new required keys)

### feat: seed infra template with k8s manifests and AWS terraform modules
- **Scope:** `k8s/base/`, `k8s/overlays/aws/`, `terraform/aws/`, `.gitignore`
- **Sync impact:**
  - `k8s/base/` — auto-sync safe
  - `k8s/overlays/aws/` — manual merge (contains your image tags and secrets)
  - `terraform/aws/modules/` — auto-sync safe
  - `terraform/aws/main.tf`, `variables.tf`, `outputs.tf` — manual merge (your variable values)
  - `.gitignore` — manual merge
