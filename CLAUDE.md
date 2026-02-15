# Eve Horizon Infrastructure

This repo manages the deployment of an Eve Horizon instance. It contains Kubernetes manifests, Terraform modules, deploy workflows, and an operational CLI.

## Quick Orientation

```
config/
  platform.yaml          # Deployment config (version, domain, cloud, resources)
  secrets.env.example    # Template for secrets (never committed)
  kubeconfig.yaml        # Local kubeconfig (gitignored, auto-detected by CLI)

k8s/
  base/                  # Shared Kubernetes manifests
  overlays/aws/          # AWS-specific patches (images, secrets, ingress, TLS)
  overlays/gcp/          # GCP-specific patches (nginx ingress, node affinity, Filestore)

terraform/aws/           # Terraform modules (network, ec2, rds, dns, security)
terraform/gcp/           # Terraform modules (network, gke, sql, dns, ollama)

bin/eve-infra            # Operational CLI (status, deploy, logs, db, secrets)

.github/workflows/
  deploy.yml             # Deploy on tag push, manual dispatch, or repository_dispatch
  health-check.yml       # Cron health check
  upgrade-check.yml      # Cron version upgrade detection
```

## Kubeconfig

**AWS (k3s):** Place your kubeconfig at `config/kubeconfig.yaml` (gitignored). The CLI and kubectl will auto-detect it. Ensure it uses the server's **public IP**, not `127.0.0.1`.

**GCP (GKE):** Run `gcloud container clusters get-credentials <cluster> --zone <zone>`. The CLI auto-detects `~/.kube/config` when `cloud: gcp`.

## Key Commands

```bash
./bin/eve-infra status     # Pod status, versions, resource usage
./bin/eve-infra health     # Health check the API endpoint
./bin/eve-infra logs api   # Tail API logs (also: worker, orchestrator, gateway, agent-runtime)
./bin/eve-infra deploy     # Trigger deploy workflow
./bin/eve-infra db connect # Open psql session
```

## Skills

Install agent skills:

```bash
eve skills install
```

This reads `skills.txt` and installs from `skills/` into `.agent/skills/` + `.claude/skills/`. The `eve-infra-ops` skill provides operational guidance for debugging and managing this deployment.

## Upstream Sync (Template Repo)

This repo is an **infrastructure template**. Downstream users clone it (not fork) to deploy their own Eve Horizon instance. The upstream sync system keeps downstream repos in sync with template improvements.

**For template maintainers** (this repo):
- Always update `CHANGELOG.md` when making changes — include sync impact annotations
- Use the sync policy tiers when deciding where new files belong
- New shared infrastructure goes in "always" paths; instance-customizable files go in "ask" paths

**For downstream repos:**
- `.upstream-sync.json` tracks sync state (created by `eve-infra sync init`, committed to your repo)
- `CHANGELOG.md` documents every template change with sync guidance per file
- Use `eve-infra sync check` to see pending upstream changes categorized by policy
- Use the `upstream-sync` skill for agent-driven sync with review of "ask" files

**Sync policy tiers:**
- **always** — shared infra overwritten from upstream (`k8s/base/`, `terraform/*/modules/`, `bin/eve-infra`, `scripts/`, `.github/workflows/`, `skills/`)
- **never** — instance-specific, never touched (`config/platform.yaml`, `config/secrets.env`, `terraform/*/terraform.tfvars`)
- **ask** — may have local customizations, review before accepting (`k8s/overlays/`, `terraform/*/main.tf`, `CLAUDE.md`, docs)
