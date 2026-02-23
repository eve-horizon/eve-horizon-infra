# Upgrade Guide

How to upgrade your Eve Horizon deployment to a new platform version.

## Table of Contents

- [Checking for New Versions](#checking-for-new-versions)
- [Upgrade Steps](#upgrade-steps)
- [Zero-Downtime Rollout](#zero-downtime-rollout)
- [Handling Breaking Changes](#handling-breaking-changes)
- [Rollback](#rollback)

---

## Checking for New Versions

### From the CLI

```bash
bin/eve-infra version
```

This shows your current pinned version and queries GitHub for the latest upstream release tag (`release-v*` on `Incept5/eve-horizon`). Uses `gh api` if available, falls back to `git ls-remote`. If a newer version exists, it tells you the exact command to upgrade.

### Manually

Check the upstream repository for release tags:

- GitHub tags: `https://github.com/Incept5/eve-horizon/tags`
- ECR gallery: `https://gallery.ecr.aws/w7c4v0w3/eve-horizon/api`

---

## Upgrade Steps

### 1. Update Configuration

```bash
bin/eve-infra upgrade 0.2.0
```

This single command:
- Updates `platform.version` in `config/platform.yaml`
- Updates all image tags in `k8s/overlays/<cloud>/*-patch.yaml`, including env var refs like `EVE_RUNNER_IMAGE`

### 2. Review Changes

```bash
git diff
```

Inspect the changes. The upgrade command only touches version strings -- if the diff looks right, proceed.

### 3. Commit

```bash
git add -A
git commit -m "chore: upgrade eve platform to 0.2.0"
```

### 4. Deploy

```bash
bin/eve-infra deploy
bin/eve-infra db migrate    # Run if the release includes schema changes
bin/eve-infra health
```

The deploy applies manifests via kustomize, then waits for all rollouts to complete. See [Zero-Downtime Rollout](#zero-downtime-rollout) for how this works without service interruption.

### 5. Verify

```bash
bin/eve-infra status        # Confirm all pods are running the new version
bin/eve-infra health        # Confirm the API is healthy
bin/eve-infra logs api      # Watch for errors
```

---

## Zero-Downtime Rollout

All deployments are configured for zero-downtime upgrades using Kubernetes rolling updates.

### How It Works

Each Deployment has:

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1        # Create 1 new pod before killing the old one
    maxUnavailable: 0  # Never take down the old pod until the new one is ready
```

The rollout sequence:

1. Kubernetes creates a new pod alongside the existing one (`maxSurge: 1`)
2. The new pod pulls the updated image and starts
3. Kubernetes waits for the readiness probe (`/health`) to pass
4. Once ready, the old pod receives SIGTERM
5. A `preStop` hook (`sleep 5`) runs first, giving the endpoints controller time to remove the old pod from the Service -- this prevents in-flight requests from hitting a terminating pod
6. After the sleep, the process receives SIGTERM and shuts down gracefully
7. The old pod terminates within `terminationGracePeriodSeconds`

With `replicas: 1`, this means zero gap -- the new pod serves traffic before the old one dies.

### Grace Periods

| Service | terminationGracePeriodSeconds | Why |
|---------|-------------------------------|-----|
| api, gateway, orchestrator | 30s | Standard HTTP request draining |
| worker | 60s | Longer window for job dispatch draining |
| agent-runtime (StatefulSet) | 30s | Uses `updateStrategy: RollingUpdate` |

### What's Not Included (Yet)

- **PodDisruptionBudgets** -- with `replicas: 1`, PDBs would block node drains. Add when scaling to 2+.
- **Multiple replicas** -- `maxSurge: 1` + `maxUnavailable: 0` already gives zero-downtime with 1 replica.

---

## Handling Breaking Changes

### Before Upgrading

1. Check the release notes in the Eve Horizon source repository for the target version
2. Look for notes about:
   - Database schema changes (migrations run automatically, but check for manual steps)
   - Changed environment variables (compare `secrets.env.example` across versions)
   - New required configuration fields in `platform.yaml`
   - Removed or renamed services
   - Changed API endpoints

### Configuration Changes

If a new version introduces new fields in `platform.yaml`:

```bash
# Compare your config against the template from the new version
diff config/platform.yaml <(curl -sf https://raw.githubusercontent.com/eve-horizon/eve-horizon-infra/main/config/platform.yaml)
```

If a new version adds new secrets:

```bash
# Compare your secrets template against the latest
diff config/secrets.env.example <(curl -sf https://raw.githubusercontent.com/eve-horizon/eve-horizon-infra/main/config/secrets.env.example)
```

Add any new required fields before deploying.

### Kustomize Overlay Changes

If the upstream template adds new base manifests or overlay patches, you may need to sync your `k8s/` directory. Check the template repo's commit log for changes to `k8s/base/kustomization.yaml` and `k8s/overlays/`.

### Database Migrations

Migrations run as a Kubernetes Job before the main deploy. If a migration fails:

```bash
# Check migration logs
kubectl logs job/eve-db-migrate -n eve

# Delete the failed job, fix the issue, retry
kubectl delete job eve-db-migrate -n eve
bin/eve-infra db migrate
```

For major schema changes, consider taking a database backup first:

```bash
bin/eve-infra db backup    # Shows backup instructions for your provider
```

---

## Rollback

### Immediate Rollback (Kubernetes)

If the new version is misbehaving, roll back to the previous revision:

```bash
# Roll back all services
for d in eve-api eve-gateway eve-orchestrator eve-worker; do
  kubectl rollout undo deployment/$d -n eve
done
kubectl rollout undo statefulset/eve-agent-runtime -n eve

# Verify
bin/eve-infra status
bin/eve-infra health
```

This uses Kubernetes' built-in rollout history and takes effect in seconds.

### Pinned Rollback (Full)

To roll back at the configuration level (so future deploys also use the old version):

```bash
# Revert platform.yaml and overlays to the previous version
bin/eve-infra upgrade 0.1.28    # Specify the version to go back to

# Commit
git add -A
git commit -m "chore: rollback eve platform to 0.1.28"

# Deploy the rollback
bin/eve-infra deploy
bin/eve-infra health
```

### Database Rollback

Eve migrations are forward-only. If a migration introduced a breaking schema change and you need to roll back:

1. Restore from a database backup (see `bin/eve-infra db backup` for provider-specific instructions)
2. Then roll back the application version as described above

### Verifying a Rollback

After any rollback, confirm the system is healthy:

```bash
bin/eve-infra status             # All pods Running, correct image version
bin/eve-infra health             # API responding 200
bin/eve-infra logs api           # No errors in recent logs
bin/eve-infra db connect         # Verify data integrity if needed
```
