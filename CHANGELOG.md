# Changelog

All notable changes to the `eve-horizon-infra` template.

Downstream repos: consult this during `upstream-sync` operations.
Each entry includes **Sync impact** to guide what downstream agents need to do.

---

## [2026-11-05]

### fix: stop custom domains from claiming platform hosts on GCP

The GCP DNS module published an apex and a `*.<domain>` wildcard at the
platform ingress, so any name under the domain passed custom-domain DNS
verification and a project could serve `auth.<domain>`, `sso.<domain>` or
similar. DNS now publishes only named platform hosts and `*.apps.<domain>`,
and a GKE admission policy refuses tenant ingresses on platform hosts.

- **Scope:** `terraform/gcp/modules/dns/` (`main.tf`, `variables.tf`,
  `outputs.tf`), `terraform/gcp/main.tf`, `terraform/gcp/variables.tf`,
  `terraform/gcp/outputs.tf`, `terraform/gcp/terraform.tfvars.example`,
  `k8s/overlays/gcp/ingress-host-policy.yaml` (new),
  `k8s/overlays/gcp/kustomization.yaml`,
  `k8s/overlays/gcp/{worker,api,sso,supabase-auth}-deployment-patch.yaml`,
  `k8s/overlays/gcp/{sso,supabase-auth}-ingress-patch.yaml`,
  `k8s/overlays/gcp/dashboard-ingress-patch.yaml` (new),
  `scripts/validate-template.sh`, `scripts/validate-template.d/` (new)
- **What changes:**
  - DNS: A records for `dns_platform_hosts` (default `api`, `registry`,
    `auth`, `sso`, `dashboard`, `ingress`) under the domain, plus
    `*.apps.<domain>`. The apex and `*.<domain>` exist only while
    `dns_legacy_wildcard_records = true` (default `false`). The existing
    `registry` record moves into the new set in state (`moved` block), so it
    is not recreated. Root output `api_url` now reports `https://api.<domain>`.
  - Admission (`eve-ingress-host-guard`, Kubernetes 1.30+): an Ingress
    written by an Eve controller, or by anyone into an environment
    namespace (label `eve.env_id`), may only use hosts under the platform
    domain that are under the app domain; no wildcard or host-less rules
    and no default backend. Custom domains outside the platform domain and
    the platform's own ingresses in `eve` are unaffected.
  - The GKE API now gets `EVE_DEFAULT_DOMAIN` (it had none, so its
    custom-domain check did nothing), and the overlay placeholder becomes
    `apps.eve.example.com` to match the DNS app wildcard.
  - Every GKE platform host now sits under the platform domain, because
    the host guard only reserves names under it: SSO and GoTrue move from
    `sso.example.com` and `auth.example.com` to `sso.<domain>` and
    `auth.<domain>` (ingress hosts, TLS hosts, `SUPABASE_AUTH_EXTERNAL_URL`,
    `API_EXTERNAL_URL`, `GOTRUE_SITE_URL`, the GoTrue CORS origin), the SSO
    session cookie domain (`EVE_DEFAULT_DOMAIN` on `eve-sso`) becomes the
    platform domain, and the dashboard Ingress (previously the base
    `dashboard.eve.lvh.me` with no class) is served by ingress-nginx at
    `dashboard.<domain>` (`dashboard-ingress-patch.yaml`, new). With no class,
    GKE's built-in controller had claimed it and built a separate Google
    load balancer outside the platform DNS; GKE removes that load balancer
    once the class changes.
- **Sync impact:**
  - `terraform/gcp/modules/dns/` — **action required: this removes live DNS
    records.** Names that resolved only through `*.<domain>` or the apex stop
    resolving. Migrate in two applies:
    1. List every host you serve under `<domain>` (platform ingresses, any
       ops tools, custom domains under the domain). Add any label missing
       from the default to `dns_platform_hosts`.
    2. Apply with `dns_legacy_wildcard_records = true`: this adds the named
       records and keeps the apex and wildcard. Check each host resolves
       (`dig +short api.<domain>`).
    3. Remove the setting (default `false`) and apply again: Terraform
       destroys only the apex and `*.<domain>` records.
    A single apply also works, but destroys the wildcard while creating the
    named records, so a resolver may cache a miss for a platform host for up
    to the zone's negative TTL (Cloud DNS default: 300 seconds).
  - `terraform/gcp/{main,variables,outputs}.tf`, `terraform.tfvars.example` —
    manual merge (pass the two DNS variables through; fix `api_url`).
  - `k8s/overlays/gcp/` — manual merge. Set the policy's `platformDomain` to
    your Terraform `domain` and `appDomain` to your `EVE_DEFAULT_DOMAIN`
    (`apps.<domain>`), and set the same `EVE_DEFAULT_DOMAIN` on the API.
    If your SSO, auth or dashboard hosts sit outside the platform domain,
    move them under it (update GoTrue's redirect URLs, the OAuth providers'
    callback URLs and any bookmarked login links); otherwise keep them and
    add their exact names to the host guard yourself.
    Before applying, check `kubectl get ingress -A` for environment-namespace
    hosts under `<domain>` but outside `apps.<domain>`: their next deploy
    will be refused; move them to an app alias or a domain you own.
  - `scripts/` — template CI assertions (no unconditional apex or wildcard
    record; DNS host defaults agree; policy domains, worker and API
    `EVE_DEFAULT_DOMAIN` and the API host agree; every platform ingress and
    TLS host is under the platform domain and has a record; auth and SSO
    URLs point at served hosts; the SSO cookie domain is the platform
    domain).

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
