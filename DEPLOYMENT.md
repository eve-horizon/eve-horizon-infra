# Deployment Guide

Complete guide to deploying and operating an Eve Horizon instance. This covers first-time setup through to day-to-day operations.

## Table of Contents

- [First-Time Deployment](#first-time-deployment)
  - [1. Create Your Repository](#1-create-your-repository)
  - [2. Configure platform.yaml](#2-configure-platformyaml)
  - [3. Create secrets.env](#3-create-secretsenv)
  - [4. Provision Infrastructure (Terraform)](#4-provision-infrastructure-terraform)
  - [5. Fetch Kubeconfig](#5-fetch-kubeconfig)
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
| `cloud` | `aws` or `gcp` | Selects Terraform root + k8s overlay defaults |
| `region` | `eu-west-1` or `us-central1` | Cloud region for resources |
| `domain` | `eve.acme.com` | Must be under a managed DNS zone you control |
| `api_host` | `api.eve.acme.com` | Convention: `api.<domain>` |
| `app_domain` | `apps.acme.com` | Wildcard DNS recommended for deployed apps |
| `route53_zone_id` | `Z0123456789ABC` | Required for AWS (Route53) |
| `gcp_project_id` | `my-project-id` | Required for GCP |
| `dns_zone_name` | `example-com` | Required for GCP Cloud DNS |
| `tls.email` | `ops@acme.com` | For Let's Encrypt certificate notifications |
| `ssh_public_key` | `ssh-ed25519 AAAA...` | Contents of your `.pub` file |
| `compute.type` | `m6i.xlarge` | See comments in the file for sizing guidance |
| `database.provider` | `rds` or `cloud-sql` | Managed DB provider should match cloud |
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
- `DATABASE_URL` -- constructed from Terraform output after provisioning (see step 4)
- `GHCR_USERNAME` + `GHCR_TOKEN` -- GitHub PAT with `read:packages` scope
- `ANTHROPIC_API_KEY` and/or `OPENAI_API_KEY` -- at least one LLM provider
- `GITHUB_TOKEN` -- PAT with `repo`, `read:org` scopes

**Never commit `secrets.env`.** It is already in `.gitignore`.

### 4. Provision Infrastructure (Terraform)

```bash
# Pick terraform root from config/platform.yaml (aws|gcp)
CLOUD="$(grep '^cloud:' config/platform.yaml | awk '{print $2}')"

# Create your Terraform variable file
cp "terraform/${CLOUD}/terraform.tfvars.example" "terraform/${CLOUD}/terraform.tfvars"
$EDITOR "terraform/${CLOUD}/terraform.tfvars"
```

Fill in values that match your `platform.yaml`. The key fields to set:

- `name_prefix` and `environment` -- must match `platform.yaml`
- `region` (canonical; legacy `aws_region`/`gcp_region` aliases still supported) -- must match `platform.yaml`
- DNS fields (`domain` + `route53_zone_id` for AWS, `domain` + `dns_zone_name` for GCP)
- `ssh_public_key` -- same key as `platform.yaml`
- `db_password` -- generate a strong password
- `allowed_ssh_cidrs` -- restrict to your IP

Then provision:

```bash
terraform -chdir="terraform/${CLOUD}" init
terraform -chdir="terraform/${CLOUD}" plan     # Review what will be created
terraform -chdir="terraform/${CLOUD}" apply    # Type "yes" to confirm

# Save the outputs -- you'll need them
terraform -chdir="terraform/${CLOUD}" output
terraform -chdir="terraform/${CLOUD}" output -raw database_url   # -> paste into secrets.env as DATABASE_URL
terraform -chdir="terraform/${CLOUD}" output -raw ssh_command    # -> use to connect to the server
```

Terraform creates cloud networking, managed database, DNS records, and cluster compute for the selected provider.

### 5. Fetch Kubeconfig

After Terraform completes, configure kubeconfig:

```bash
# The exact command is in terraform output for your selected cloud
terraform -chdir="terraform/${CLOUD}" output -raw kubeconfig_command | bash

# Verify connectivity
kubectl get nodes
```

You should see one or more nodes in `Ready` state.

### 6. Run Cluster Setup

The setup script installs cluster-level prerequisites: the `eve` namespace, cert-manager, Let's Encrypt issuers, the container registry pull secret, and application secrets.

```bash
./scripts/setup.sh
```

Prerequisites for this step:
- `kubectl` configured (step 5)
- `helm` v3 installed (for cert-manager)
- `config/secrets.env` populated (step 3, with DATABASE_URL from step 4)

### 7. Deploy Eve Horizon

```bash
# Deploy all services
bin/eve-infra deploy

# Run database migrations
bin/eve-infra db migrate

# Verify
bin/eve-infra health
```

The deploy command builds kustomize manifests from `k8s/overlays/<cloud>/` and applies them to the cluster, then waits for all rollouts to complete.

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

### SSH Access

```bash
# Pick terraform root from config/platform.yaml (aws|gcp)
CLOUD="$(grep '^cloud:' config/platform.yaml | awk '{print $2}')"

# Get the SSH command from Terraform outputs
terraform -chdir="terraform/${CLOUD}" output -raw ssh_command

# AWS (k3s): direct SSH
ssh ubuntu@<server-ip>                  # if cloud=aws
sudo kubectl get pods -n eve

# GCP (GKE): node SSH for debugging
gcloud compute ssh --project=<project> --zone=<zone> <node-name>  # if cloud=gcp
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
- `KUBECONFIG` -- required for direct kubeconfig mode (AWS/custom overlays)
- `GCP_SA_KEY`, `GCP_PROJECT_ID`, `GKE_CLUSTER_NAME`, `GKE_ZONE` -- required for GCP deploys
- `REGISTRY_TOKEN` -- GitHub PAT with `read:packages` scope
- `SLACK_WEBHOOK_URL` -- (optional) for deploy notifications

The workflow runs migrations, applies manifests, waits for rollouts, runs a health check, and auto-rolls-back on failure.

### Health Check Workflow (`.github/workflows/health-check.yml`)

Runs every 30 minutes. Hits `https://<api_host>/health` with 3 retries. On failure:
- Creates a GitHub issue (or comments on an existing open one to avoid duplicates)
- Sends a Slack notification (if `SLACK_WEBHOOK_URL` is configured)

### Upgrade Check Workflow (`.github/workflows/upgrade-check.yml`)

Runs daily at 08:00 UTC. Queries the container registry for the latest semver tag. If a newer version is available, opens a PR that bumps `config/platform.yaml`. Avoids duplicate PRs.

Required GitHub secrets:
- `REGISTRY_TOKEN` -- GitHub PAT with `read:packages` scope

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

The cluster cannot pull images from `ghcr.io/eve-horizon`.

```bash
# Check the registry secret exists
kubectl get secret eve-registry -n eve

# If missing, re-run setup or create manually
kubectl create secret docker-registry eve-registry \
  --docker-server=ghcr.io \
  --docker-username=<your-username> \
  --docker-password=<your-token> \
  -n eve
```

Verify your `GHCR_TOKEN` has `read:packages` scope and has not expired.

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
- DNS not yet propagated (Route53/Cloud DNS changes can take a few minutes)
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
- Managed DB network access is misconfigured (Terraform should wire this, but verify)
- Database instance does not exist yet (Terraform creates it for managed providers)

### Cannot Reach the API (Connection Refused / Timeout)

1. Check DNS resolution: `dig api.eve.example.com`
2. Check the server is reachable: `curl -sk https://<server-ip>:443`
3. Check the API pod is running: `kubectl get pods -n eve -l app.kubernetes.io/name=eve-api`
4. Check the ingress: `kubectl get ingress -n eve`
5. Check ingress controller logs (`traefik` on k3s, `ingress-nginx` on GKE):
   `kubectl logs -n kube-system -l app.kubernetes.io/name=traefik`
   `kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx`

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
CLOUD="$(grep '^cloud:' config/platform.yaml | awk '{print $2}')"
terraform -chdir="terraform/${CLOUD}" destroy

# Start fresh from step 4
```
