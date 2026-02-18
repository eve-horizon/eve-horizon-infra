# Deployment Guide

Complete guide to deploying and operating an Eve Horizon instance. This covers first-time setup through to day-to-day operations.

## Table of Contents

- [First-Time Deployment](#first-time-deployment)
  - [1. Create Your Repository](#1-create-your-repository)
  - [2. Configure platform.yaml](#2-configure-platformyaml)
  - [3. Create secrets.env](#3-create-secretsenv)
  - [4. Provision Infrastructure (Terraform)](#4-provision-infrastructure-terraform)
  - [5. Configure Kubeconfig](#5-configure-kubeconfig)
  - [6. Run Cluster Setup](#6-run-cluster-setup)
  - [7. Deploy Eve Horizon](#7-deploy-eve-horizon)
  - [8. Verify](#8-verify)
- [Day-to-Day Operations](#day-to-day-operations)
- [CI/CD Workflows](#cicd-workflows)
- [Monitoring](#monitoring)
- [Troubleshooting](#troubleshooting)

---

## First-Time Deployment

### 1. Create Your Repository

Create a private copy from the template. Do not fork -- you want a clean, independent repo for your infrastructure state.

```bash
gh repo create my-org/eve-infra \
  --template eve-horizon/eve-horizon-infra \
  --private \
  --clone

cd eve-infra
```

### 2. Configure platform.yaml

Open `config/platform.yaml` and set every field marked `[REQUIRED]`:

```bash
$EDITOR config/platform.yaml
```

Key fields to change:

| Field | Example | Notes |
|-------|---------|-------|
| `name_prefix` | `acme-eve-prod` | Unique per deployment in the same cloud account |
| `cloud` | `aws` | Only `aws` is supported today |
| `region` | `eu-west-1` | AWS region for all resources |
| `domain` | `eve.acme.com` | Must be under a Route53 hosted zone you control |
| `api_host` | `api.eve.acme.com` | Convention: `api.<domain>` |
| `app_domain` | `apps.acme.com` | Wildcard DNS recommended for deployed apps |
| `route53_zone_id` | `Z0123456789ABC` | Found in AWS Console > Route53 |
| `tls.email` | `ops@acme.com` | For Let's Encrypt certificate notifications |
| `ssh_public_key` | `ssh-ed25519 AAAA...` | Contents of your `.pub` file |
| `compute.type` | `m6i.xlarge` | See comments in the file for sizing guidance |
| `database.provider` | `rds` | Use `rds` for production, `in-cluster` for dev |
| `network.allowed_ssh_cidrs` | `["203.0.113.42/32"]` | Restrict to your IP |

The file is heavily commented -- read through it once before deploying.

### 3. Create secrets.env

```bash
cp config/secrets.env.example config/secrets.env
$EDITOR config/secrets.env
```

Generate the required cryptographic keys:

```bash
# Master encryption key
openssl rand -hex 32    # -> EVE_SECRETS_MASTER_KEY

# Internal service-to-service key
openssl rand -hex 32    # -> EVE_INTERNAL_API_KEY

# Bootstrap token (for initial admin setup)
openssl rand -hex 32    # -> EVE_BOOTSTRAP_TOKEN

# Database password (also used in terraform.tfvars)
openssl rand -base64 24 # -> used in DATABASE_URL
```

Set at minimum:

- `EVE_SECRETS_MASTER_KEY`, `EVE_INTERNAL_API_KEY`, `EVE_BOOTSTRAP_TOKEN`
- `DATABASE_URL` -- constructed after Terraform provisions RDS (see step 4)
- Registry pull credentials only if using a private registry (for example `GHCR_USERNAME` + `GHCR_TOKEN`)
- `ANTHROPIC_API_KEY` and/or `OPENAI_API_KEY` -- at least one LLM provider
- `GITHUB_TOKEN` -- PAT with `repo`, `read:org` scopes

**Never commit `secrets.env`.** It is already in `.gitignore`.

### 4. Provision Infrastructure (Terraform)

```bash
# Create your Terraform variable file
cp terraform/aws/terraform.tfvars.example terraform/aws/terraform.tfvars
$EDITOR terraform/aws/terraform.tfvars
```

Fill in values that match your `platform.yaml`. The key fields to set:

- `name_prefix` -- must match `platform.yaml`
- `region` -- must match `platform.yaml`
- `compute_model` -- `k3s` or `eks` (must match `platform.yaml` `compute.model`)
- `domain` and `route53_zone_id` -- must match `platform.yaml`
- `ssh_public_key` -- same key as `platform.yaml`
- `db_password` -- generate a strong password
- `allowed_ssh_cidrs` -- restrict to your IP

Then provision:

```bash
cd terraform/aws
terraform init
terraform plan     # Review what will be created
terraform apply    # Type "yes" to confirm

# Save the outputs -- you'll need them
terraform output
terraform output -raw database_url   # -> paste into secrets.env as DATABASE_URL
# k3s mode:
terraform output -raw ssh_command     # -> use to connect to the server
# EKS mode:
terraform output -raw cluster_name
terraform output -raw cluster_autoscaler_irsa_role_arn
```

Terraform always creates VPC/subnets/security groups/RDS/DNS and then:
- `k3s` mode: a single EC2 host with k3s.
- `eks` mode: EKS control plane + managed node groups + IRSA roles + registry S3.

### 5. Configure Kubeconfig

After Terraform completes, configure `kubectl` based on your compute model:

```bash
# k3s mode: the exact command is in terraform output
terraform output -raw kubeconfig_command | bash

# EKS mode:
aws eks update-kubeconfig --name <name_prefix>-cluster --region <region>

# Verify connectivity for either mode
kubectl get nodes
```

In `k3s` mode you should see one node. In `eks` mode you should see the default managed node group.

### 6. Run Cluster Setup

The setup script installs cluster-level prerequisites: the `eve` namespace, cert-manager, Let's Encrypt issuers, registry pull secret, app secrets, and EKS extras (nginx-ingress + cluster-autoscaler) when `overlay: aws-eks`.

```bash
./scripts/setup.sh
```

Prerequisites for this step:
- `kubectl` configured (step 5)
- `helm` v3 installed (for cert-manager)
- `config/secrets.env` populated (step 3, with DATABASE_URL from step 4)

If using `compute_model=eks`, once ingress-nginx is installed and the NLB exists, complete DNS alias cutover:

```bash
# Get ingress controller NLB details
kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'

# Set ingress_lb_dns_name and ingress_lb_zone_id in terraform.tfvars, then:
terraform -chdir=terraform/aws apply -target=module.dns
```

### 7. Deploy Eve Horizon

```bash
# Deploy all services
bin/eve-infra deploy

# Run database migrations
bin/eve-infra db migrate

# Verify
bin/eve-infra health
```

The deploy command builds kustomize manifests from `k8s/overlays/<overlay>/` (from `config/platform.yaml`) and applies them to the cluster, then waits for rollouts.

### 8. Verify

```bash
# Full status overview
bin/eve-infra status

# Check all pods are Running
kubectl get pods -n eve

# Hit the API
curl -sf https://<your-api-host>/health | jq .

# Tail API logs to watch for errors
bin/eve-infra logs api
```

If everything is healthy, your Eve Horizon instance is live.

---

## GPU Inference (optional)

Eve can provision an on-demand GPU instance for local LLM inference via Ollama.

1. Set `ollama_enabled = true` in your `terraform.tfvars`
2. Run `terraform apply`
3. Add the Terraform outputs to your Eve deployment:
   - `EVE_OLLAMA_BASE_URL` -- from the GPU instance's private IP
   - `EVE_OLLAMA_ASG_NAME` -- from `terraform output ollama_asg_name`
4. Redeploy Eve: the API auto-registers the GPU target on startup
5. Register models via CLI:
   ```bash
   eve ollama model add --canonical llama-3.3-70b --provider ollama --slug llama3.3:70b-instruct-q4_K_M
   ```

The GPU starts cold (no cost). When an inference request arrives, Eve wakes
the GPU (~90s), serves the request, and auto-stops after 30 minutes idle.

**Cost:** Only pay for actual GPU time. EBS ($8/mo) is the only fixed cost.
Typical staging usage: $20-35/mo.

---

## Day-to-Day Operations

### Deploying Changes

After updating `platform.yaml` or any k8s manifests:

```bash
bin/eve-infra deploy
```

Or trigger a deploy via CI by pushing a tag:

```bash
git tag deploy-v0.1.28
git push origin deploy-v0.1.28
```

### Managing Secrets

When you add or rotate secrets:

```bash
# Edit the secrets file
$EDITOR config/secrets.env

# Push to the cluster
bin/eve-infra secrets sync

# Restart services to pick up new values
bin/eve-infra restart api
bin/eve-infra restart worker
```

To see which keys are currently configured in the cluster:

```bash
bin/eve-infra secrets show
```

### Restarting Services

```bash
bin/eve-infra restart api            # Rolling restart (zero-downtime)
bin/eve-infra restart worker
bin/eve-infra restart orchestrator
bin/eve-infra restart gateway
bin/eve-infra restart agent-runtime
```

### Viewing Logs

```bash
bin/eve-infra logs api               # Tail API logs
bin/eve-infra logs worker            # Tail worker logs
bin/eve-infra logs orchestrator
bin/eve-infra logs gateway
bin/eve-infra logs agent-runtime
```

### Database Operations

```bash
bin/eve-infra db migrate             # Run pending migrations
bin/eve-infra db connect             # Interactive psql session
bin/eve-infra db backup              # Show backup instructions for your provider
```

### SSH Access (k3s Mode)

```bash
# Get the SSH command from Terraform outputs
terraform -chdir=terraform/aws output -raw ssh_command

# Or directly
ssh ubuntu@<server-ip>

# On the server, k3s commands require sudo
sudo kubectl get pods -n eve
sudo k3s kubectl logs -n eve deployment/eve-api
```

For EKS mode, use AWS auth instead of SSH:

```bash
aws eks update-kubeconfig --name <name_prefix>-cluster --region <region>
kubectl get nodes
```

---

## CI/CD Workflows

Three GitHub Actions workflows are included:

### Deploy Workflow (`.github/workflows/deploy.yml`)

Deploys Eve to the cluster. Triggered by:

- **Tag push:** `deploy-v0.1.28` -- extracts version from the tag
- **Manual dispatch:** run from GitHub Actions UI, optionally specify a version
- **Repository dispatch:** `type: deploy` with `version` in the payload (for cross-repo CI)

Required GitHub secrets:
- `KUBECONFIG` -- required for non-EKS deployments (base64-encoded kubeconfig)
- `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` -- required for EKS deployments
- `REGISTRY_TOKEN` -- required only when `platform.registry` uses `ghcr.io/*`
- `SLACK_WEBHOOK_URL` -- (optional) for deploy notifications

The workflow runs migrations, applies manifests, waits for rollouts, runs a health check, and auto-rolls-back on failure.

Local safety guardrails:
- `bin/eve-infra` and `scripts/setup.sh` validate active kube context before mutating operations.
- Use `EVE_KUBE_GUARD_BYPASS=1` only for intentional break-glass operations.
- Prefer per-repo kubeconfig/profile isolation (`direnv` + `config/kubeconfig.yaml`) to avoid cross-repo context leakage.

### Health Check Workflow (`.github/workflows/health-check.yml`)

Runs every 30 minutes. Hits `https://<api_host>/health` with 3 retries. On failure:
- Creates a GitHub issue (or comments on an existing open one to avoid duplicates)
- Sends a Slack notification (if `SLACK_WEBHOOK_URL` is configured)

### Upgrade Check Workflow (`.github/workflows/upgrade-check.yml`)

Runs daily at 08:00 UTC. Queries the container registry for the latest semver tag. If a newer version is available, opens a PR that bumps `config/platform.yaml`. Avoids duplicate PRs.

Required GitHub secrets:
- `REGISTRY_TOKEN` -- required only when `platform.registry` uses `ghcr.io/*`

---

## Monitoring

### Health Checks

```bash
# Manual health check
bin/eve-infra health

# The health-check workflow also runs every 30 minutes automatically
```

### Pod Status

```bash
bin/eve-infra status                 # Full overview
kubectl get pods -n eve -o wide      # Detailed pod view
kubectl top pods -n eve              # Resource usage (if metrics-server is installed)
```

### Cluster Events

```bash
kubectl get events -n eve --sort-by=.lastTimestamp | tail -20
```

### Observability

If `observability.otel_enabled` is set to `true` in `platform.yaml`, all Eve services export traces and metrics via OpenTelemetry to the configured `otel_endpoint`. Connect this to your preferred backend (Grafana, Datadog, etc.).

---

## Troubleshooting

### Pods stuck in ImagePullBackOff

The cluster cannot pull images from the configured `platform.registry`.

```bash
# Check what registry is configured
yq '.platform.registry' config/platform.yaml

# Check for recent pull/auth errors
kubectl get events -n eve --sort-by=.lastTimestamp | tail -50

# Check whether an imagePullSecret is still configured on workloads
kubectl -n eve get deploy,statefulset -o yaml | rg -n "imagePullSecrets|eve-registry"
```

If `platform.registry` is public ECR (`public.ecr.aws/...`), no pull secret is required.

If you're using a private registry (GHCR/private ECR/custom), ensure the pull secret exists:

```bash
kubectl get secret eve-registry -n eve

# If missing, re-run setup or create manually (example for GHCR)
kubectl create secret docker-registry eve-registry \
  --docker-server=ghcr.io \
  --docker-username=<your-username> \
  --docker-password=<your-token> \
  -n eve
```

For GHCR, verify `GHCR_TOKEN` has `read:packages` scope and has not expired.

### Pods stuck in CrashLoopBackOff

A service is failing to start. Check its logs:

```bash
bin/eve-infra logs api
# Look for missing environment variables, database connection errors, etc.
```

Common causes:
- `DATABASE_URL` is wrong or the database is unreachable
- Missing required secrets (`EVE_SECRETS_MASTER_KEY`, `EVE_INTERNAL_API_KEY`)
- Database migrations have not been run (`bin/eve-infra db migrate`)

### TLS Certificate Not Issuing

```bash
# Check cert-manager pods
kubectl get pods -n cert-manager

# Check certificate status
kubectl get certificates -n eve
kubectl describe certificate <name> -n eve

# Check the issuer
kubectl get clusterissuer
kubectl describe clusterissuer letsencrypt-prod
```

Common causes:
- `tls.email` not set in `platform.yaml` (setup.sh warns about this)
- DNS not yet propagated (Route53 changes can take a few minutes)
- Using `letsencrypt-prod` during testing and hitting rate limits -- switch to `letsencrypt-staging` first

### Database Migration Fails

```bash
# Check migration job logs
kubectl logs job/eve-db-migrate -n eve

# Delete the failed job and retry
kubectl delete job eve-db-migrate -n eve
bin/eve-infra db migrate
```

Common causes:
- `DATABASE_URL` is incorrect in `secrets.env`
- RDS security group does not allow connections from compute nodes (EC2 or EKS node SG)
- Database does not exist yet (Terraform's RDS module creates it)

### Cannot Reach the API (Connection Refused / Timeout)

1. Check DNS resolution: `dig api.eve.example.com`
2. Check the server is reachable: `curl -sk https://<server-ip>:443`
3. Check the API pod is running: `kubectl get pods -n eve -l app.kubernetes.io/name=eve-api`
4. Check the ingress: `kubectl get ingress -n eve`
5. Check ingress controller logs:
   - aws-eks: `kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller`
   - k3s: `kubectl logs -n kube-system -l app.kubernetes.io/name=traefik`

### Deploy Workflow Fails

The deploy workflow includes automatic rollback on failure. Check the workflow run in GitHub Actions for diagnostics (pod status, events, deployment descriptions are all printed on failure).

If the rollback itself fails or you need manual intervention:

```bash
# Roll back a specific service
kubectl rollout undo deployment/eve-api -n eve

# Or roll back everything
for d in eve-api eve-gateway eve-orchestrator eve-worker; do
  kubectl rollout undo deployment/$d -n eve
done
kubectl rollout undo statefulset/eve-agent-runtime -n eve
```

### Resetting From Scratch

If you need to tear down and rebuild (non-production only):

```bash
# Delete all Eve resources from the cluster
kubectl delete namespace eve

# Destroy cloud infrastructure
cd terraform/aws && terraform destroy

# Start fresh from step 4
```
