---
name: eve-infra-ops
description: Operate, debug, and manage this Eve Horizon deployment instance. Use when checking health, tailing logs, debugging pod issues, running migrations, or understanding the deployment layout.
---

# Eve Infra Ops

Use this skill to operate and debug this Eve Horizon deployment instance.

## When to Use

- Checking deployment health and pod status
- Debugging failing services or pods
- Tailing logs for a specific service
- Running database migrations
- Understanding the repo layout and how deploys work
- Investigating why a deploy failed

## Kubeconfig Setup

Place your kubeconfig at `config/kubeconfig.yaml` (gitignored). The CLI and kubectl auto-detect it.

**Important:** The kubeconfig must use the server's **public IP**, not `127.0.0.1`. k3s generates configs with localhost — fix before use:

```bash
sed -i 's|https://127.0.0.1:6443|https://<PUBLIC_IP>:6443|' config/kubeconfig.yaml
```

Resolution order: `$KUBECONFIG` env > `config/kubeconfig.yaml` > `~/.kube/eve-<name_prefix>.yaml` > default

## Quick Health Check

```bash
# CLI health check (reads api_host from config/platform.yaml)
./bin/eve-infra health

# Or directly
curl -f https://$(grep api_host config/platform.yaml | awk '{print $2}')/health

# Full status: pods, services, versions
./bin/eve-infra status
```

## Operational CLI Reference

All commands read from `config/platform.yaml` and auto-resolve kubeconfig.

```bash
./bin/eve-infra <command>
```

| Command | Purpose |
|---------|---------|
| `status` | Pod status, versions, resource usage |
| `version` | Current version + check for latest |
| `health` | Health check the API endpoint |
| `logs <service>` | Tail logs (api, worker, orchestrator, gateway, agent-runtime) |
| `restart <service>` | Rolling restart a service |
| `deploy` | Apply current manifests to cluster |
| `upgrade <ver>` | Update version in config + patches |
| `db migrate` | Run database migration job |
| `db backup` | Show backup instructions |
| `db connect` | Open psql session |
| `secrets show` | List configured secret keys |
| `secrets sync` | Push secrets.env to cluster |

## Debugging with kubectl

When the CLI isn't enough, use kubectl directly. With kubeconfig at `config/kubeconfig.yaml`, it's auto-detected by the CLI. For raw kubectl, set:

```bash
export KUBECONFIG=config/kubeconfig.yaml
```

### Pod Status

```bash
kubectl -n eve get pods -o wide
kubectl -n eve get pods -o wide | grep -v Running  # Find unhealthy pods
```

### Logs

```bash
# Tail API logs
kubectl -n eve logs -f deployment/eve-api --all-containers

# Last 50 lines from worker
kubectl -n eve logs deployment/eve-worker --tail=50

# Logs from a specific pod
kubectl -n eve logs <pod-name>

# Previous container logs (if restarting)
kubectl -n eve logs <pod-name> --previous
```

### Pod Details

```bash
# Why is a pod failing?
kubectl -n eve describe pod <pod-name>

# Check events (most recent last)
kubectl -n eve get events --sort-by='.lastTimestamp' | tail -20

# Shell into a running pod
kubectl -n eve exec -it deployment/eve-api -- sh
```

### Service & Ingress

```bash
# Check services
kubectl -n eve get svc

# Check ingress rules
kubectl -n eve get ingress
kubectl -n eve describe ingress eve-api

# Check traefik (ingress controller)
kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik
kubectl -n kube-system logs -l app.kubernetes.io/name=traefik --tail=20
```

### Rollout Management

```bash
# Check rollout status
kubectl -n eve rollout status deployment/eve-api

# Rollback to previous version
kubectl -n eve rollout undo deployment/eve-api

# Restart without changing version
kubectl -n eve rollout restart deployment/eve-api
```

### Secrets

```bash
# List keys in the app secret
kubectl -n eve get secret eve-app -o json | jq -r '.data | keys[]'

# Decode a specific value
kubectl -n eve get secret eve-app -o json | jq -r '.data.DATABASE_URL' | base64 -d

# Check registry secret
kubectl -n eve get secret eve-registry -o yaml
```

### Persistent Volumes

```bash
kubectl -n eve get pvc
kubectl -n eve describe pvc eve-org-fs-org-default
```

**Warning:** Never delete the `eve-org-fs-org-default` PVC while agent-runtime is running — the finalizer will deadlock.

## Common Failure Patterns

### ImagePullBackOff

```bash
kubectl -n eve describe pod <pod-name> | grep -A5 "Events"
```

**Causes:**
- Image version doesn't exist — check `config/platform.yaml` version matches published tags
- Registry secret missing or expired — verify `eve-registry` secret
- Network issue reaching ghcr.io

### CrashLoopBackOff

```bash
kubectl -n eve logs <pod-name> --previous
```

**Causes:**
- DATABASE_URL wrong or unreachable — check secret and RDS security group
- Missing env vars — compare secret keys to what the service expects
- Migration not run — `./bin/eve-infra db migrate`

### Migration Job Stuck

```bash
kubectl -n eve get jobs
kubectl -n eve describe job/eve-db-migrate
kubectl -n eve logs job/eve-db-migrate
```

**Fix:** Delete stale job and re-run:
```bash
kubectl -n eve delete job eve-db-migrate
./bin/eve-infra db migrate
```

### Ingress 404/502

```bash
kubectl -n eve get ingress -o wide
kubectl -n eve describe ingress eve-api
```

**Causes:**
- Ingress host doesn't match DNS
- Service not ready (check pods)
- TLS certificate not issued (check cert-manager logs)

## Repo Layout

```
config/
  platform.yaml          # Version, domain, cloud, resources
  secrets.env.example    # Template — copy to secrets.env (gitignored)
  kubeconfig.yaml        # Local kubeconfig (gitignored)

k8s/
  base/                  # Shared k8s manifests (don't modify per-instance)
  overlays/<cloud>/      # Cloud-specific patches (images, secrets, ingress)

terraform/<cloud>/       # Infrastructure-as-code modules

bin/eve-infra            # Operational CLI

.github/workflows/
  deploy.yml             # Triggered by tag, dispatch, or repository_dispatch
```

## Deploy Flow

Deploys are triggered three ways:

1. **Tag push:** `git tag deploy-v0.1.86 && git push origin deploy-v0.1.86`
2. **Manual dispatch:** `gh workflow run deploy.yml` (with optional version override)
3. **Automatic:** Source repo pushes `repository_dispatch` after building images

The workflow: read config → resolve version → configure kubectl → update image tags → run migrations → apply manifests → wait for rollouts → health check. Auto-rollback on failure.
