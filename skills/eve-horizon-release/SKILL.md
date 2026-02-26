---
name: eve-horizon-release
description: Tag a new eve-horizon platform release. Bumps the semver patch, tags the source repo, and updates platform.yaml to match. Use when cutting a new staging release.
---

# Eve Horizon Release

Tag a new release of the eve-horizon source repo, which builds + publishes images and auto-deploys to staging.

## When to Use

- Cutting a new platform release for staging
- User says "tag a release", "cut a release", "new release", "deploy new version"

## Prerequisites

- The eve-horizon repo must be checked out at `../eve-horizon` (relative to this infra repo)
- You must have push access to the eve-horizon remote

## Procedure

### 1. Gather State

Run these in parallel:

```bash
# Latest release tag
cd ../eve-horizon && git tag --sort=-v:refname | grep '^release-v' | head -1

# Unreleased commits since last tag (the changelog)
cd ../eve-horizon && git log $(git tag --sort=-v:refname | grep '^release-v' | head -1)..HEAD --oneline

# Current branch and clean working tree check
cd ../eve-horizon && git status --short && git branch --show-current

# Current platform.yaml version in this infra repo
grep 'version:' config/platform.yaml
```

### 2. Present the Release

Show the user:

1. **Current version** — the latest `release-v*` tag
2. **Next version** — bump the patch number (e.g., `0.1.146` -> `0.1.147`)
3. **Changelog** — the commits that will be included
4. **Branch** — must be `main` (warn if not)
5. **Working tree** — must be clean (warn if not)

Ask for confirmation before proceeding. If there are no unreleased commits, tell the user there's nothing new to release.

### 3. Tag and Push

After user confirms:

```bash
cd ../eve-horizon && git tag release-v<NEXT_VERSION> && git push origin release-v<NEXT_VERSION>
```

### 4. Update platform.yaml

Update the version in this infra repo's `config/platform.yaml` to match the new release:

```yaml
platform:
  version: "<NEXT_VERSION>"
```

Then commit and push:

```bash
git add config/platform.yaml
git commit -m "chore: bump platform version to <NEXT_VERSION>"
git push
```

### 5. Report

Tell the user:

- The tag that was pushed
- That the publish-images workflow is now running (link: `https://github.com/Incept5/eve-horizon/actions`)
- That once images are built, a `repository_dispatch` will auto-trigger the deploy workflow on this repo
- That they can monitor the deploy at `https://github.com/Incept5/incept5-eve-infra/actions`

## What Happens After Tagging

```
release-v0.1.147 pushed to eve-horizon
  -> publish-images.yml runs (builds 6 service images ~3-5 min)
  -> pushes images to public.ecr.aws/w7c4v0w3/eve-horizon/*:0.1.147
  -> repository_dispatch -> incept5-eve-infra
     -> deploy.yml runs (migrations, apply, rollout, health check ~3-5 min)
```

Total time from tag to live: ~6-10 minutes.

## Safety Notes

- Never tag from a branch other than `main` without explicit user approval
- Never tag if the working tree is dirty
- Always show the changelog and get confirmation before tagging
- The deploy workflow has auto-rollback on failure
