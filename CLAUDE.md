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

terraform/aws/           # Terraform modules (network, ec2, rds, dns, security)

bin/eve-infra            # Operational CLI (status, deploy, logs, db, secrets)

.github/workflows/
  deploy.yml             # Deploy on tag push, manual dispatch, or repository_dispatch
  health-check.yml       # Cron health check
  upgrade-check.yml      # Cron version upgrade detection
```

## Kubeconfig

Place your kubeconfig at `config/kubeconfig.yaml` (gitignored). The CLI and kubectl will auto-detect it. Ensure it uses the server's **public IP**, not `127.0.0.1`.

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
