# Changelog

All notable changes to the `eve-horizon-infra` template.

Downstream repos: consult this during `upstream-sync` operations.
Each entry includes **Sync impact** to guide what downstream agents need to do.

---

## [2026-11-05]

### fix: keep API signing keys out of other services and carry PEM keys intact

- **Scope:** `scripts/render-k8s-secrets.py` (new), `bin/eve-infra`,
  `scripts/setup.sh`, `k8s/base/api-deployment.yaml`, `k8s/base/app-secret.yaml`,
  `k8s/overlays/{aws,aws-eks}/api-deployment-patch.yaml`,
  `k8s/overlays/aws-eks/{kustomization.yaml,remove-app-secret.yaml}`,
  `config/secrets.env.example`, `DEPLOYMENT.md`, `README.md`,
  `skills/eve-infra-ops/`, `scripts/validate-template.sh`,
  `tests/test_k8s_secrets.py` (new)
- **Why:** every service loaded every platform secret through `envFrom: eve-app`,
  so the worker, orchestrator, gateway, SSO and agent runtime held the keys
  that mint user and registry tokens and decrypt org secrets. Separately,
  `kubectl create secret --from-env-file` reads one line per key, so the
  multi-line PEM keys the example promised could not be synced at all.
- **What changed:** `secrets sync` (and `setup.sh`, which now calls it) renders
  two secrets from `config/secrets.env`: `eve-app` for every service and
  `eve-api-keys` for the keys only the API reads (`EVE_SECRETS_MASTER_KEY`,
  `EVE_AUTH_PRIVATE_KEY`, `EVE_AUTH_JWT_SECRET`, `EVE_REGISTRY_SIGNING_KEY`,
  `EVE_BOOTSTRAP_TOKEN`, `EVE_ORG_FS_LINK_TOKEN_SECRET`,
  `EVE_GITHUB_WEBHOOK_SECRET`, `SUPABASE_AUTH_SERVICE_KEY`). Only `eve-api`
  mounts `eve-api-keys` (optional reference). The env file accepts
  double-quoted multi-line values (and `\n` escapes inside double quotes);
  unquoted values are read verbatim as before. The example documents
  `EVE_AUTH_PRIVATE_KEY` with a generation command, marks the API-only keys,
  and moves LLM and GitHub keys to Eve org secrets. The aws-eks overlay no
  longer renders the blank `eve-app` placeholder, which a deploy would have
  applied over the synced values.
- **Sync impact:**
  - `k8s/base/`, `bin/eve-infra`, `scripts/` — **action required, in order:**
    sync, then `eve-infra deploy` (the API now also loads the optional
    `eve-api-keys`; nothing else changes yet), then `eve-infra secrets sync`
    (moves the API-only keys out of `eve-app`), then restart services so they
    drop the old values. `secrets sync` refuses to run until the live
    `eve-api` Deployment loads `eve-api-keys`, so the keys cannot vanish from
    the API on a restart. `secrets sync` now needs `python3`.
  - `config/secrets.env` — no edit needed for single-line values. Values that
    start with a quote are now unquoted (`KEY="v"` gives `v`, where kubectl
    kept the quotes); a value that opens a quote must close it at the end of
    a line. A PEM must be wrapped in double quotes; an unquoted one is
    rejected with the line number, never the value.
  - `k8s/overlays/{aws,aws-eks}/api-deployment-patch.yaml` — manual merge
    (`EVE_REGISTRY_SIGNING_KEY` now reads from `eve-api-keys`)
  - `k8s/overlays/aws-eks/` — manual merge (add `remove-app-secret.yaml` and
    its patch entry)
  - `config/secrets.env.example`, `DEPLOYMENT.md`, `skills/eve-infra-ops/` —
    informational
  - `scripts/validate-template.sh`, `tests/` — template CI: renders must not
    contain `eve-app`/`eve-api-keys`, and only `eve-api` may reference
    `eve-api-keys` or an API-only key

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
