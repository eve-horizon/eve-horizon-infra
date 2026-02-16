# Upgrade Guide

How to upgrade your Eve Horizon deployment to a new platform version.

## Table of Contents

- [Checking for New Versions](#checking-for-new-versions)
- [Upgrade Steps (Manual)](#upgrade-steps-manual)
- [Upgrade Steps (Automated)](#upgrade-steps-automated)
- [Handling Breaking Changes](#handling-breaking-changes)
- [Rollback](#rollback)

---

## Checking for New Versions

### From the CLI

```bash
bin/eve-infra version
```

This shows your current pinned version and queries the container registry for the latest available tag. If a newer version exists, it tells you the exact command to upgrade.

### From GitHub Actions

The **Upgrade Check** workflow (`.github/workflows/upgrade-check.yml`) runs daily at 08:00 UTC. If a newer version is found, it automatically opens a pull request that bumps `config/platform.yaml`.

You can also trigger it manually from the GitHub Actions tab.

### Manually

Check the registry configured in `config/platform.yaml` for available tags:

- Public ECR (default): `https://gallery.ecr.aws/w7c4v0w3/eve-horizon/api`
- GHCR mirror: `https://github.com/orgs/eve-horizon/packages`

---

## Upgrade Steps (Manual)

### 1. Update Configuration

```bash
bin/eve-infra upgrade 0.2.0
```

This single command:
- Updates `platform.version` in `config/platform.yaml`
- Updates all image tags in `k8s/overlays/<cloud>/*-patch.yaml`

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

**Option A -- Deploy locally:**

```bash
bin/eve-infra deploy
bin/eve-infra db migrate    # Run if the release includes schema changes
bin/eve-infra health
```

**Option B -- Deploy via CI:**

```bash
git push origin main
git tag deploy-v0.2.0
git push origin deploy-v0.2.0
```

The deploy workflow handles migrations, rollout, health checks, and automatic rollback on failure.

### 5. Verify

```bash
bin/eve-infra status        # Confirm all pods are running the new version
bin/eve-infra health        # Confirm the API is healthy
bin/eve-infra logs api      # Watch for errors
```

---

## Upgrade Steps (Automated)

The automated flow requires no manual intervention for routine version bumps:

1. The **Upgrade Check** workflow detects a new version and opens a PR
2. Review the PR (it shows current vs. new version)
3. Merge the PR
4. Trigger a deploy:
   - Push a tag: `git tag deploy-v<version> && git push origin deploy-v<version>`
   - Or run the Deploy workflow manually from the Actions tab
5. The deploy workflow runs migrations, applies manifests, waits for rollouts, runs health checks, and rolls back automatically if anything fails

### Setting Up Automated Deploys

To make the flow fully automated (merge PR triggers deploy), add a `push` trigger to `.github/workflows/deploy.yml`:

```yaml
on:
  push:
    branches: [main]
    paths: ['config/platform.yaml']
```

This triggers a deploy whenever `platform.yaml` changes on `main` -- which is exactly what the upgrade PR does.

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
# Look for new [REQUIRED] fields
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

### CI Rollback

If you deployed via the deploy workflow:

1. The workflow automatically rolls back all services on failure
2. For a manual CI rollback, run the Deploy workflow from the Actions tab and specify the old version in the input field

### Database Rollback

Eve migrations are forward-only. If a migration introduced a breaking schema change and you need to roll back:

1. Restore from a database backup (see `bin/eve-infra db backup` for provider-specific instructions)
2. Then roll back the application version as described above

For RDS:

```bash
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier <instance-id>-restored \
  --db-snapshot-identifier <snapshot-id>
```

### Verifying a Rollback

After any rollback, confirm the system is healthy:

```bash
bin/eve-infra status             # All pods Running, correct image version
bin/eve-infra health             # API responding 200
bin/eve-infra logs api           # No errors in recent logs
bin/eve-infra db connect         # Verify data integrity if needed
```
