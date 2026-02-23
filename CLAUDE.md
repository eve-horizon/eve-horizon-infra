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
./bin/eve-infra deploy     # Apply manifests to cluster (kustomize build + kubectl apply)
./bin/eve-infra upgrade <ver>  # Bump version in platform.yaml + all overlay patches
./bin/eve-infra db connect # Open psql session
```

## Version Upgrades

Upgrade the platform:

```bash
./bin/eve-infra upgrade <version>   # Updates config/platform.yaml + k8s/overlays/gcp/*-patch.yaml
git add -A && git commit -m "chore: upgrade eve platform to <version>"
./bin/eve-infra deploy              # Rolls out new images to cluster
./bin/eve-infra health              # Verify
```

Images are pulled from `public.ecr.aws/w7c4v0w3/eve-horizon/<service>:<version>`.

## Upstream Platform Fixes

The upstream Eve Horizon platform source lives at `../../incept5/eve-horizon` (GitHub: `Incept5/eve-horizon`). To ship a hotfix:

1. Fix the bug in the upstream repo
2. Commit and push to main
3. Tag `release-v<next>` and push — triggers CI to build all images (~5-10 min)
4. Run `eve-infra upgrade <next>` + `eve-infra deploy` in this repo

See the `eve-horizon-hotfix` skill for the full workflow.

## Skills

Install agent skills:

```bash
eve skills install
```

This reads `skills.txt` and installs from `skills/` into `.agent/skills/` + `.claude/skills/`.

Available local skills:
- `eve-infra-ops` — operational guidance for debugging and managing this deployment
- `eve-horizon-hotfix` — fix bugs in upstream eve-horizon, tag releases, deploy to cluster
- `eve-template-backport-sync` — backport reusable changes to the upstream infra template
- `upstream-sync` — sync downstream with upstream template changes
- `redeploy-if-necessary` — check for new upstream releases and deploy with zero downtime
- `check-spend` — audit live GCP spend, itemize costs, flag savings opportunities

## Cost Management

Infrastructure costs are controlled via `terraform/gcp/terraform.tfvars`. Three sizing profiles:

| Profile | Compute | Database | Disk | Est. $/mo |
|---------|---------|----------|------|-----------|
| **Dev** | e2-standard-2, min 1 node | db-g1-small | 50GB pd-balanced | ~$150 |
| **Staging** | e2-standard-4, min 1 node | db-custom-2-8192 | 50GB pd-balanced | ~$300 |
| **Production** | e2-standard-4, min 2 nodes | db-custom-4-16384 | 100GB pd-ssd | ~$600 |

To audit current spend and find savings: `check-spend` skill or review `terraform.tfvars` directly.

Key cost levers:
- **Machine type:** e2-standard-2 vs e2-standard-4 (biggest single factor)
- **Disk type:** pd-balanced vs pd-ssd (pd-balanced avoids SSD quota limits too)
- **Database tier:** db-g1-small (~$27/mo) vs db-custom-2-8192 (~$125/mo)
- **Node pool min counts:** 0 for agents/apps means pay-per-use

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
