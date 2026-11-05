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
| `compute.model` | `k3s` or `eks` | AWS only. `k3s` keeps single EC2, `eks` uses managed cluster |
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
| `overlay` | `aws`, `aws-eks`, or `gcp` | Defaults to cloud. Use `aws-eks` with `compute.model: eks` |
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

# Database password (also used in terraform.tfvars); URL-safe for DATABASE_URL
openssl rand -base64 24 | tr -d '/+=' # -> db_password and DATABASE_URL

# Token-signing key. A PEM spans several lines, so it goes in double quotes.
# Delete the empty EVE_AUTH_PRIVATE_KEY= line from secrets.env, then:
printf 'EVE_AUTH_PRIVATE_KEY="%s"\n' "$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048)" >> config/secrets.env
```

Set at minimum:

- `EVE_SECRETS_MASTER_KEY`, `EVE_INTERNAL_API_KEY`, `EVE_BOOTSTRAP_TOKEN`, `EVE_AUTH_PRIVATE_KEY`
- `DATABASE_URL` -- constructed from Terraform output after provisioning (see step 4)

`bin/eve-infra secrets sync` (run by `scripts/setup.sh`) writes two Kubernetes
secrets from this file: `eve-app`, which every Eve service loads, and
`eve-api-keys`, which holds the keys marked `[API ONLY]` in the example (the
secrets master key, the token-signing keys, the bootstrap token) and which
only the API mounts. Multi-line values such as PEM keys must be wrapped in
double quotes; `\n` inside double quotes is also read as a line break.

LLM provider keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, etc.), Claude Code
tokens and the GitHub token (`GITHUB_TOKEN`) are Eve org secrets, set with the
Eve CLI after bootstrap (`eve secrets set <KEY> <value> --scope org --org <org-id>`),
not cluster secrets. Anything you put in `secrets.env` lands in `eve-app` and
so in every service pod, the agent runtime included.

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
- if `compute_model = "eks"`:
  - set EKS node group sizing (`eks_default_*`, `eks_agents_*`, `eks_apps_*`)
  - after ingress is provisioned, set `ingress_lb_dns_name` + `ingress_lb_zone_id` for Route53 alias records

Then provision:

```bash
terraform -chdir="terraform/${CLOUD}" init
terraform -chdir="terraform/${CLOUD}" plan     # Review what will be created
terraform -chdir="terraform/${CLOUD}" apply    # Type "yes" to confirm

# Save the outputs -- you'll need them
terraform -chdir="terraform/${CLOUD}" output
terraform -chdir="terraform/${CLOUD}" output -raw database_host  # -> host part of DATABASE_URL
terraform -chdir="terraform/${CLOUD}" output -raw ssh_command    # -> use to connect to the server
```

Build `DATABASE_URL` in `secrets.env` from that host and your `terraform.tfvars`:
`postgres://<db_username>:<db_password>@<database_host>:5432/<db_name>` (the
username and database name default to `eve`). Terraform has no output that
contains the password, so `terraform output -json` never prints it.

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

The deploy command builds manifests from `k8s/overlays/<overlay>/` (`overlay` from `config/platform.yaml`, falling back to `cloud`) and applies them to the cluster, then waits for rollouts to complete.

On overlays that run the Eve-native registry for app images (`gcp`, `aws-eks`), deploy then checks that `https://<registry host>/v2/` answers `401` with a `WWW-Authenticate: Bearer realm=` challenge, and fails if it does not: a registry that misses its token-auth config would let anyone push and pull. The host comes from the overlay's `eve-registry` ingress. Keep it, the `realm` in the overlay's `registry-configmap-patch.yaml` (`https://<api_host>/internal/registry/token`) and `EVE_REGISTRY_HOST` in `secrets.env` in step. The registry trusts tokens signed by `EVE_REGISTRY_SIGNING_KEY` (an RSA key); `scripts/setup.sh` loads the matching certificate into the `eve-registry-cert` secret from `REGISTRY_SIGNING_CERT_PATH`. On a first install, before DNS and a certificate exist for the registry host, run `bin/eve-infra deploy --skip-registry-check` once, then deploy again without it.

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

# Push to the cluster (eve-app + the API-only eve-api-keys)
bin/eve-infra secrets sync

# Restart services to pick up new values
bin/eve-infra restart api
bin/eve-infra restart worker
```

On a cluster deployed before the `eve-api-keys` split, run `bin/eve-infra deploy`
once before the first sync: the sync moves the API's keys out of `eve-app` and
refuses to run until the API Deployment loads `eve-api-keys`.

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

## Deploying Updates

Deploys are run locally via the CLI. The process is zero-downtime -- new pods are created and pass health checks before old pods terminate.

```bash
bin/eve-infra version              # Check for new upstream releases
bin/eve-infra upgrade <version>    # Bump config + all image refs
git diff                           # Review
git add -A && git commit -m "chore: upgrade eve platform to <version>"
bin/eve-infra deploy               # Zero-downtime rollout
bin/eve-infra health               # Verify
```

See [UPGRADE.md](UPGRADE.md) for the full upgrade guide, including zero-downtime rollout details, breaking change handling, and rollback procedures.

Safety guardrails:
- `bin/eve-infra` validates the active kube context before mutating operations
- Use `EVE_KUBE_GUARD_BYPASS=1` only for intentional break-glass operations

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

The cluster cannot pull images from `public.ecr.aws`.

```bash
# Check pod events for the exact error
kubectl describe pod <pod-name> -n eve | grep -A5 "Events"
```

Common causes:
- Image tag doesn't exist (check `config/platform.yaml` version matches a published release)
- Network issue reaching ECR public registry
- If using a private registry, check the `eve-registry` pull secret exists

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

### Deploy Fails the Registry Auth Check

`bin/eve-infra deploy` stops when the registry does not demand a bearer token.

- **HTTP 200:** the registry is serving without its token-auth config, so anyone can push and pull. Check that the `eve-registry` container's `args` name the file its config volume provides (`/etc/distribution/config.yml` in the base) and that `scripts/validate-template.sh` passes on your overlays.
- **502 or 503:** the registry pod is not ready, often because the `eve-registry-cert` secret is missing (`kubectl -n eve describe pod -l app.kubernetes.io/name=eve-registry`).
- **No response or a TLS error:** DNS or the certificate for the registry host is not ready yet (see the next section). Deploy with `--skip-registry-check` until it is, then deploy again without it.
- **401 without a `Bearer` challenge:** something other than the Eve registry answers on that host. Check the `eve-registry` ingress.

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
5. Check ingress controller logs (`traefik` on k3s, `ingress-nginx` on GKE/AWS EKS):
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
