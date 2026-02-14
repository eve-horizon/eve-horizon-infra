---
name: upstream-sync
description: Sync this downstream deployment repo with the upstream eve-horizon-infra template. Use when upstream has new features, security fixes, Terraform modules, CLI improvements, or workflow updates that should be incorporated into this instance.
---

# Upstream Sync

Use this skill to incorporate changes from the upstream `eve-horizon-infra` template into this downstream deployment repo.

## When to Use

- Upstream template has new features (Terraform modules, CLI commands, workflows)
- Security or bug fixes in base manifests, scripts, or workflows
- Periodic maintenance sync (recommended: monthly or on upstream release)
- Before deploying a new platform version (sync infra first, then upgrade app)

## Prerequisites

- Git CLI available
- Network access to the upstream repo
- Clean working tree (commit or stash local changes first)

## Initialization (First-Time Setup)

If `.upstream-sync.json` does not exist, run initialization before syncing.

### Step 1: Add the upstream remote

```bash
./bin/eve-infra sync init
```

This command:
1. Adds `upstream` as a git remote pointing to the template repo
2. Fetches upstream history
3. Finds the merge-base (the commit where this repo diverged)
4. Creates `.upstream-sync.json` from the `.upstream-sync.example.json` template
5. Records the merge-base as `last_sync.commit`

### Step 2: Verify state

```bash
./bin/eve-infra sync status
```

Confirm the remote URL, merge-base commit, and sync policy look correct.

## The Sync Workflow

Follow these steps in order. Each step builds on the previous.

### Step 1: Assess what changed upstream

```bash
./bin/eve-infra sync check
```

This fetches `upstream/main` and shows:
- Number of new commits since last sync
- Files changed, categorized by sync policy (always/ask/never)
- Time since last sync

Review the output before proceeding.

### Step 2: Read the upstream CHANGELOG

```bash
git show upstream/main:CHANGELOG.md
```

Look at entries since the last sync date. Each entry has a **Sync impact** annotation telling you whether changes auto-sync safely, need manual review, or are informational only.

### Step 3: Create a sync branch

```bash
git checkout -b sync/upstream-$(date +%Y-%m-%d)
```

All sync work happens on this branch. If anything goes wrong, delete the branch — main is untouched.

### Step 4: Compute the file diff

```bash
git diff --name-only $(jq -r '.last_sync.commit' .upstream-sync.json)..upstream/main
```

Categorize each changed file against the sync policy in `.upstream-sync.json`.

### Step 5: Apply "always" files

These are safe to overwrite — they contain no instance-specific configuration:

```bash
# For each file matching an "always" pattern:
git checkout upstream/main -- <path>
```

Typical "always" paths:
- `k8s/base/` — shared Kubernetes manifests
- `terraform/*/modules/` — reusable Terraform modules
- `bin/eve-infra` — operational CLI
- `scripts/` — utility scripts
- `.github/workflows/` — CI/CD workflows
- `skills/` and `skills.txt` — agent skills

### Step 6: Review "ask" files

These files may contain instance-specific customizations. For each one:

1. Run `git diff upstream/main -- <path>` to see what upstream changed
2. Decide whether to accept, merge manually, or skip
3. If accepting: `git checkout upstream/main -- <path>`
4. If merging: edit the file to incorporate upstream changes while preserving local customizations

Typical "ask" paths and guidance:

| Path | Guidance |
|------|----------|
| `k8s/overlays/` | Upstream may add new patches; merge carefully to keep your image tags and secrets |
| `terraform/*/main.tf` | New modules may be added; keep your existing variable values |
| `terraform/*/variables.tf` | New variables may be added with defaults; review and customize |
| `terraform/*/outputs.tf` | Usually safe to accept |
| `.gitignore` | Merge — keep both upstream and local ignores |
| `CLAUDE.md` | Merge — upstream may add new sections; keep your customizations |
| `README.md` | Merge if you've customized; otherwise accept upstream |
| `CHANGELOG.md` | Accept upstream version (it documents the template, not your instance) |

### Step 7: Skip "never" files

These are instance-specific and must never be overwritten:
- `config/platform.yaml` — your version, domain, cloud settings
- `config/secrets.env` — your secrets
- `config/kubeconfig.yaml` — your cluster access
- `.upstream-sync.json` — your sync state (updated in Step 9)
- `terraform/*/terraform.tfvars` — your Terraform variable values

Do not touch these files during sync. If upstream added new config keys, add them manually after reviewing.

### Step 8: Stage and check for conflicts

```bash
git add -A
git status
```

If there are merge conflicts (unlikely with the checkout approach, but possible if you manually merged):
- Resolve each conflict, preserving instance-specific values
- Common conflict areas: overlay patches (image tags), terraform variables

### Step 9: Update sync state

Update `.upstream-sync.json` with the sync results:

```bash
# Get the upstream commit hash
UPSTREAM_COMMIT=$(git rev-parse upstream/main)

# Update using jq
jq --arg commit "$UPSTREAM_COMMIT" \
   --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   --arg summary "Synced to upstream $(git log -1 --format=%s upstream/main)" \
   '.last_sync.commit = $commit |
    .last_sync.timestamp = $ts |
    .last_sync.summary = $summary |
    .history += [{commit: $commit, timestamp: $ts, summary: $summary}]' \
   .upstream-sync.json > .upstream-sync.json.tmp && mv .upstream-sync.json.tmp .upstream-sync.json
```

Stage the updated state file:

```bash
git add .upstream-sync.json
```

### Step 10: Commit with structured message

```bash
git commit -m "chore: sync with upstream eve-horizon-infra

Synced to: $UPSTREAM_COMMIT
Changes: <brief summary of what was synced>
Policy: <N> always, <N> ask (reviewed), <N> never (skipped)"
```

Then merge the sync branch into main:

```bash
git checkout main
git merge sync/upstream-$(date +%Y-%m-%d)
git branch -d sync/upstream-$(date +%Y-%m-%d)
```

## Handling Significant Divergence

If the sync check shows **>50 changed files** or **>90 days since last sync**, take extra care:

1. Read the full CHANGELOG between your last sync and now
2. Look for breaking changes or migration notes
3. Consider syncing in smaller increments if possible (use intermediate commits)
4. Test thoroughly after sync — run `./bin/eve-infra status` and `./bin/eve-infra health`

## Reverting a Sync

If a sync introduced problems:

- **Before merging to main:** just delete the sync branch
  ```bash
  git checkout main
  git branch -D sync/upstream-YYYY-MM-DD
  ```

- **After merging to main:** revert the merge commit
  ```bash
  git revert -m 1 <merge-commit-hash>
  ```

The `.upstream-sync.json` state will still show the sync, but you can re-attempt later. The history array provides a full audit trail.

## Sync Policy Reference

The sync policy in `.upstream-sync.json` controls how each file is handled:

| Tier | Behavior | Rationale |
|------|----------|-----------|
| **always** | Overwrite from upstream without review | Shared infrastructure that should match the template exactly |
| **ask** | Present diff for human/agent review | Files that may have instance-specific customizations |
| **never** | Skip entirely | Instance-specific configuration that must be preserved |

To customize the policy for your instance, edit the path patterns in `.upstream-sync.json`. Use trailing `/` for directory patterns and `*` for cloud-provider wildcards (e.g., `terraform/*/modules/`).
