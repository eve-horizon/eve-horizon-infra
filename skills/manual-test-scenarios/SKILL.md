---
name: manual-test-scenarios
description: Run upstream Eve Horizon manual test scenarios against the corfai stack. Validates API health, job execution, pipelines, events, and deploy flow.
---

# Manual Test Scenarios

Run the first five upstream Eve Horizon manual test scenarios against this corfai deployment to verify the stack is operational.

## When to Use

- After a platform upgrade or domain change
- After infrastructure changes (terraform, k8s patches)
- Periodic health validation
- Before onboarding new workloads

## Scenario Source

Scenarios live in the upstream repo — never modify them:

```
../../incept5/eve-horizon/tests/manual/scenarios/
```

Read each scenario file before running it. The steps below customise auth, domain, and org context for this corfai instance.

## Corfai Stack Context

```bash
export EVE_API_URL=https://api.corf.ai
export CLUSTER_DOMAIN=apps.corf.ai
export APP_SCHEME=https
```

**Auth:** Eve CLI profile at `.eve/profile.yaml`, credentials cached at `~/.eve/credentials.json`. Token is keyed by `https://api.corf.ai`.

**Admin user:** `adam@corf.ai` (`user_01kj52jtqgesp8cge2gd6pg654`), SSH key `~/.ssh/id_ed25519_adam@corf.ai`.

**Test org:** `org_manualtestorg` — create if it doesn't exist:

```bash
eve org ensure --name "Manual Test Org" --slug manualtestorg --json
export ORG_ID=org_manualtestorg
```

## Pre-Flight

Before running scenarios, verify auth is working:

```bash
eve auth status
eve system health --json
eve org list --json
```

If auth fails (401 or expired token):

```bash
eve auth login --email adam@corf.ai --ssh-key ~/.ssh/id_ed25519_adam@corf.ai
```

## App Domain Mapping

Upstream scenarios use `CLUSTER_DOMAIN` for app URLs. On corfai:

- **Mechanical ingress:** `{service}.{orgSlug}-{projectSlug}-{env}.apps.corf.ai`
- **Vanity alias:** `{alias}.apps.corf.ai`
- **API:** `api.corf.ai`

The key difference from upstream: app subdomains are under `apps.corf.ai`, not directly under the apex. When scenarios construct URLs like `api.mto-dtest-test.${CLUSTER_DOMAIN}`, the result is `api.mto-dtest-test.apps.corf.ai`.

## Required Repos

Scenarios 02-05 depend on these repos (clone next to `eve-horizon`):

| Repo | Used By | Path |
|------|---------|------|
| `incept5/eve-horizon` | All — scenario source | `../../incept5/eve-horizon` |
| `incept5/eve-horizon-fullstack-example` | 02, 03, 05 | `../../incept5/eve-horizon-fullstack-example` |
| `incept5/sentinel-mgr` | 07 (not in first 5) | `../../incept5/sentinel-mgr` |

## Required Secrets

Before running job/deploy scenarios, import secrets to the test org:

```bash
# Check existing secrets
eve secrets list --org $ORG_ID --json

# Required for job execution (scenario 02)
eve secrets set Z_AI_API_KEY <key> --org $ORG_ID
eve secrets set GITHUB_TOKEN <pat> --org $ORG_ID

# Required for deploy flow (scenario 05)
eve secrets set GITHUB_TOKEN <pat> --project $PROJECT_ID
eve secrets set POSTGRES_PASSWORD eve --project $PROJECT_ID
```

If a `manual-tests.secrets` file exists in the upstream repo:
```bash
eve secrets import --org $ORG_ID --file ../../incept5/eve-horizon/tests/manual/manual-tests.secrets
```

## Scenarios

### Scenario 01: Smoke Tests (~30s)

Read: `../../incept5/eve-horizon/tests/manual/scenarios/01-smoke.md`

Quick validation — API health, CLI connectivity, org secrets, harness auth.

```bash
eve system health --json
eve org list --json
eve secrets list --org $ORG_ID --json
eve harness list --org $ORG_ID --json
```

**Success:** All four commands return valid JSON, secrets include `Z_AI_API_KEY` and `GITHUB_TOKEN`, zai harness has `auth.available: true`.

### Scenario 02: Job Execution (~3-4m)

Read: `../../incept5/eve-horizon/tests/manual/scenarios/02-job-execution.md`

End-to-end job lifecycle: create project, create job, follow output.

```bash
eve project ensure \
  --org $ORG_ID \
  --name "job-test-project" \
  --slug jtest \
  --repo-url https://github.com/incept5/eve-horizon-fullstack-example \
  --branch main \
  --force \
  --json

# Capture PROJECT_ID from output, then:
eve job create \
  --project $PROJECT_ID \
  --description "List the top-level files in the repository and report what you find." \
  --harness zai \
  --json

# Follow job to completion:
eve job follow $JOB_ID
eve job show $JOB_ID --json
```

**Success:** Job completes with `phase: "done"`.

### Scenario 03: Pipelines API (~30s)

Read: `../../incept5/eve-horizon/tests/manual/scenarios/03-pipelines-api.md`

Pipeline CRUD — list, show, expand (dry-run). Requires manifest sync from a local clone.

```bash
TMPDIR=$(mktemp -d)
git clone --depth 1 https://github.com/incept5/eve-horizon-fullstack-example $TMPDIR/repo
cd $TMPDIR/repo
eve project sync --project $PROJECT_ID --json
cd -

eve pipeline list $PROJECT_ID --json
eve pipeline show $PROJECT_ID deploy-test --json

# Expand (dry-run) via API
TOKEN=$(eve auth token)
curl -s -X POST "$EVE_API_URL/projects/$PROJECT_ID/pipelines/deploy-test/runs" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"git_sha": "0000000000000000000000000000000000000000", "env_name": "test", "dry_run": true}' | jq
```

**Success:** Pipeline list returns entries, expand shows job graph with dependencies.

### Scenario 04: Events API (~30s)

Read: `../../incept5/eve-horizon/tests/manual/scenarios/04-events-api.md`

Event emit and list.

```bash
eve event emit \
  --project $PROJECT_ID \
  --type manual.test \
  --source manual \
  --payload '{"test": true, "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}' \
  --json

eve event list --project $PROJECT_ID --json
eve event list --project $PROJECT_ID --type manual.test --json
```

**Success:** Events appear in list, payload preserved, type filter works.

### Scenario 05: Deploy Flow (~3m)

Read: `../../incept5/eve-horizon/tests/manual/scenarios/05-deploy-flow.md`

Full deploy pipeline: manifest sync, env create, build + release + deploy, verify ingress.

```bash
eve project ensure \
  --org $ORG_ID \
  --name "deploy-test-project" \
  --slug dtest \
  --repo-url https://github.com/incept5/eve-horizon-fullstack-example \
  --branch main \
  --force \
  --json

# Set project secrets (see Required Secrets above)

REPO_DIR=$(mktemp -d)/repo
git clone --depth 1 https://github.com/incept5/eve-horizon-fullstack-example $REPO_DIR

# Sync manifest
eve project sync --project $PROJECT_ID --dir $REPO_DIR --json

# Create env and deploy
eve env create test --type persistent --project $PROJECT_ID --json
eve env deploy test --ref main --repo-dir $REPO_DIR --project $PROJECT_ID

# Verify mechanical ingress
curl -fsS "https://api.mto-dtest-test.apps.corf.ai/health" | jq
```

**Success:** Deploy completes, service health check returns 200.

## Running the Suite

Work through scenarios 01-05 in order. Stop at the first failure — later scenarios depend on earlier ones.

For each scenario:
1. Read the upstream scenario file for full context and debugging guidance
2. Use the corfai-specific commands from this skill for auth/domain
3. Check success criteria before moving to the next

## Debugging

```bash
# System-level
eve system status
eve system logs api --tail 50
eve system logs worker --tail 50

# Job-level
eve job diagnose $JOB_ID

# Environment-level
eve env show $PROJECT_ID test --json
eve env diagnose $PROJECT_ID test --json
eve env logs $PROJECT_ID test api --tail 200

# Infrastructure (last resort)
kubectl get pods -n eve
kubectl get certificates -n eve
kubectl get events -n eve --sort-by='.lastTimestamp' | tail -20
```
