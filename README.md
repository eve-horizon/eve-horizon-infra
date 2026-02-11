# Eve Horizon Infrastructure

Infrastructure-as-code template for deploying the [Eve Horizon](https://github.com/eve-horizon) platform. Create a private copy of this repo, fill in your configuration, and deploy a fully working Eve instance to your own cloud account.

**Current cloud support:** AWS (EC2 + RDS + Route53 on k3s)

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [Terraform](https://developer.hashicorp.com/terraform/install) | >= 1.5 | Provision cloud infrastructure |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | >= 1.28 | Interact with the k3s cluster |
| [Helm](https://helm.sh/docs/intro/install/) | v3 | Install cert-manager |
| [gh](https://cli.github.com/) | any | GitHub CLI (for automated upgrade PRs) |
| bash | 4+ | Run `eve-infra` and setup scripts |
| AWS CLI | v2 | Configure credentials for Terraform |

## Quick Start

```bash
# 1. Create your repo from the template
gh repo create my-org/eve-infra --template eve-horizon/eve-horizon-infra --private

# 2. Configure
cp config/secrets.env.example config/secrets.env
#    Edit config/platform.yaml  -- set domain, region, compute, etc.
#    Edit config/secrets.env    -- set API keys, DB password, registry creds

# 3. Provision cloud resources
cp terraform/aws/terraform.tfvars.example terraform/aws/terraform.tfvars
#    Edit terraform.tfvars with values matching platform.yaml
cd terraform/aws && terraform init && terraform apply

# 4. Set up the cluster (cert-manager, secrets, registry)
./scripts/setup.sh

# 5. Deploy Eve Horizon
bin/eve-infra deploy
bin/eve-infra db migrate
bin/eve-infra health
```

See [DEPLOYMENT.md](DEPLOYMENT.md) for the full step-by-step walkthrough.

## Repository Structure

```
eve-horizon-infra/
├── config/
│   ├── platform.yaml          # Single source of truth for your deployment
│   └── secrets.env.example    # Template for secrets (never committed)
├── bin/
│   └── eve-infra              # Operational CLI (deploy, upgrade, logs, etc.)
├── scripts/
│   └── setup.sh               # One-time cluster bootstrap
├── k8s/
│   ├── base/                  # Kustomize base manifests (all services)
│   └── overlays/
│       └── aws/               # AWS-specific patches (RDS, ALB, images)
├── terraform/
│   └── aws/                   # Terraform root module
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       ├── terraform.tfvars.example
│       └── modules/
│           ├── network/       # VPC, subnets, routing
│           ├── security/      # Security groups, SSH key pair
│           ├── ec2/           # k3s server instance
│           ├── rds/           # Managed PostgreSQL
│           └── dns/           # Route53 records
└── .github/workflows/
    ├── deploy.yml             # Push-to-deploy (tag, manual, or dispatch)
    ├── health-check.yml       # Scheduled health monitoring (every 30 min)
    └── upgrade-check.yml      # Daily version check with auto-PR
```

## Configuration

All deployment settings live in **`config/platform.yaml`** -- a single, well-commented YAML file covering platform version, cloud provider, domain, compute, database, TLS, and observability. It contains no secrets and should be committed.

Secrets live in **`config/secrets.env`** (git-ignored). See `config/secrets.env.example` for every required and optional key.

For Terraform variables, copy `terraform/aws/terraform.tfvars.example` to `terraform/aws/terraform.tfvars` and fill in values that match your `platform.yaml`.

## CLI Reference

The `bin/eve-infra` script is the day-to-day operational interface:

```
eve-infra status              # Platform overview + pod status
eve-infra version             # Current and latest available version
eve-infra upgrade <version>   # Bump version in config + overlays
eve-infra deploy              # Apply manifests to cluster
eve-infra health              # Hit the API health endpoint

eve-infra secrets sync        # Push secrets.env to the cluster
eve-infra secrets show        # List configured secret keys

eve-infra db migrate          # Run database migrations
eve-infra db backup           # Show backup instructions
eve-infra db connect          # Open interactive psql session

eve-infra logs <service>      # Tail logs (api, worker, orchestrator, gateway, agent-runtime)
eve-infra restart <service>   # Rolling restart
```

Run `bin/eve-infra --help` for the complete reference.

## Further Reading

- **[DEPLOYMENT.md](DEPLOYMENT.md)** -- First-time deployment walkthrough, day-to-day operations, monitoring, and troubleshooting
- **[UPGRADE.md](UPGRADE.md)** -- Version upgrades, breaking-change handling, and rollback procedures

## License

See the Eve Horizon project for license terms.
