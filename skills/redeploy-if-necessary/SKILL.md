---
name: redeploy-if-necessary
description: Check for new upstream Eve Horizon releases and deploy if a newer version is available. Zero-downtime upgrade with pre-flight health check and post-deploy verification.
---

# Redeploy If Necessary

Check whether a newer Eve Horizon release exists upstream. If so, upgrade and deploy with zero downtime.

## When to Use

- Routine maintenance check ("is there a new version?")
- Scheduled upgrade passes
- After tagging a hotfix in the upstream eve-horizon repo
- Anytime you want to ensure the cluster is running the latest release

## Prerequisites

- `gh` CLI authenticated (`gh auth status`) or git network access to GitHub
- `kubectl` access to the cluster (`./bin/eve-infra health`)
- Clean git working tree in this repo

## The Workflow

### Step 1: Pre-flight checks

Verify the cluster is healthy before touching anything.

```bash
cd "$(git rev-parse --show-toplevel)"

# Working tree must be clean
git status --short
# If dirty, stop — commit or stash first

# Cluster must be reachable and healthy
./bin/eve-infra health
```

If health fails, do not proceed. Debug with `./bin/eve-infra status` and `./bin/eve-infra logs api` first.

### Step 2: Check for new version

```bash
./bin/eve-infra version
```

This queries GitHub tags (`release-v*` on `Incept5/eve-horizon`) and compares against the version pinned in `config/platform.yaml`.

Three outcomes:
- **"You are on the latest version"** — stop here, nothing to do
- **"Latest available: X.Y.Z"** — proceed to step 3
- **"Could not determine latest version"** — check network/auth, or verify manually at `https://github.com/Incept5/eve-horizon/tags`

### Step 3: Upgrade version refs

```bash
NEW_VERSION="<version from step 2>"
./bin/eve-infra upgrade "$NEW_VERSION"
```

This updates:
- `config/platform.yaml` — the `platform.version` field
- `k8s/overlays/<cloud>/*-patch.yaml` — all image tags, including env var refs like `EVE_RUNNER_IMAGE`

### Step 4: Review the diff

```bash
git diff
```

Verify:
- Only version strings changed (no unexpected file modifications)
- All image refs updated consistently (grep to confirm):

```bash
grep -r "$NEW_VERSION" k8s/overlays/ config/platform.yaml
```

### Step 5: Commit

```bash
git add config/platform.yaml k8s/overlays/
git commit -m "chore: upgrade eve platform to $NEW_VERSION"
```

### Step 6: Deploy (zero-downtime)

```bash
./bin/eve-infra deploy
```

The deploy uses kustomize to build manifests and applies them to the cluster. Each service rolls out with:

- `maxSurge: 1, maxUnavailable: 0` — new pod starts before old pod terminates
- Readiness probe (`/health`) gates traffic — no requests hit the new pod until it's ready
- `preStop: sleep 5` — lets the endpoints controller deregister the old pod before SIGTERM
- `terminationGracePeriodSeconds` — 30s for most services, 60s for worker (job draining)

The CLI waits for all rollouts to complete (timeout: 120s per service).

### Step 7: Post-deploy verification

```bash
./bin/eve-infra health
./bin/eve-infra status
```

Confirm:
- Health check returns 200
- All pods are Running with the new image version
- No restarts or CrashLoopBackOff

Optionally tail logs briefly to watch for errors:

```bash
./bin/eve-infra logs api
```

### Step 8: Push

```bash
git push origin main
```

## If Something Goes Wrong

### New pod fails readiness probe

The rollout stalls. The old pod keeps serving. No downtime occurred.

```bash
# Check what's wrong with the new pod
kubectl get pods -n eve
kubectl describe pod <new-pod> -n eve
./bin/eve-infra logs api

# Roll back the stuck deployment
kubectl rollout undo deployment/eve-api -n eve
```

### New version has a bug (discovered after rollout)

```bash
# Immediate: roll back all services via k8s history
for d in eve-api eve-gateway eve-orchestrator eve-worker; do
  kubectl rollout undo deployment/$d -n eve
done
kubectl rollout undo statefulset/eve-agent-runtime -n eve

# Then pin the old version in config
./bin/eve-infra upgrade <PREVIOUS_VERSION>
git add -A && git commit -m "chore: rollback eve platform to <PREVIOUS_VERSION>"
./bin/eve-infra deploy
```

### Database migration failure

If the release includes schema changes and migration fails:

```bash
kubectl logs job/eve-db-migrate -n eve
kubectl delete job eve-db-migrate -n eve
# Fix the issue, then retry:
./bin/eve-infra db migrate
```

For major schema changes, take a backup first: `./bin/eve-infra db backup`

## Decision Checklist

Before deploying, confirm:

- [ ] `./bin/eve-infra health` passes (cluster is healthy now)
- [ ] `git status --short` is clean (no uncommitted work)
- [ ] `git diff` shows only version string changes
- [ ] No known breaking changes in the target version (check upstream release notes)
- [ ] Database backup taken if the release includes migrations

## Complete Example

```bash
# Check
./bin/eve-infra health
./bin/eve-infra version
# => Latest available: 0.1.141

# Upgrade
./bin/eve-infra upgrade 0.1.141
git diff
git add config/platform.yaml k8s/overlays/
git commit -m "chore: upgrade eve platform to 0.1.141"

# Deploy
./bin/eve-infra deploy
./bin/eve-infra health
./bin/eve-infra status

# Push
git push origin main
```
