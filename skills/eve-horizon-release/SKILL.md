---
name: eve-horizon-release
description: Tag and verify a new public Eve Horizon platform release. Use when publishing service images from the canonical source repo; deployment remains a separate instance-owner action.
---

# Eve Horizon Release

Tag a new release of the canonical public source repo. A release tag publishes images; it never deploys a cluster.

## When to Use

- Publishing a new platform release
- User says "tag a release", "cut a release", "new release", "deploy new version"

## Prerequisites

- The canonical repo must be checked out at `../eve-horizon`
- Its `origin` must be `eve-horizon/eve-horizon`; never push a release to the retired `Incept5` ancestor
- You must have push access to the canonical remote

## Procedure

### 1. Gather State

Run these in parallel:

```bash
# Verify canonical remote and refresh release refs
git -C ../eve-horizon remote get-url origin
git -C ../eve-horizon fetch origin main --tags

# Latest release tag and unreleased changelog
git -C ../eve-horizon tag --sort=-v:refname | grep '^release-v' | head -1
git -C ../eve-horizon log $(git -C ../eve-horizon tag --sort=-v:refname | grep '^release-v' | head -1)..HEAD --oneline

# Current branch and clean working tree check
git -C ../eve-horizon status --short
git -C ../eve-horizon branch --show-current

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

### 3. Tag and Push One Ref

After user confirms:

```bash
git -C ../eve-horizon tag release-v<NEXT_VERSION>
git -C ../eve-horizon push origin refs/tags/release-v<NEXT_VERSION>
```

Never use `git push --tags`: local history may contain release tags absent from the public remote, and every pushed `release-v*` tag triggers image publication.

### 4. Verify Publication

Monitor the public workflow and require all seven service images to succeed:

```bash
gh run list --repo eve-horizon/eve-horizon --workflow "Publish Images" --limit 1
gh run watch <RUN_ID> --repo eve-horizon/eve-horizon
```

The release is complete when `api`, `sso`, `gateway`, `agent-runtime`, `orchestrator`, `worker`, and `dashboard` are published at `<NEXT_VERSION>`.

### 5. Keep Deployment Separate

Do not edit any deployment instance's `config/platform.yaml` merely because images were published. If the user also asked for a rollout, wait for publication to pass and switch to the target instance repo's approved upgrade workflow. A source release must not use `repository_dispatch` or hold deployment credentials.

### 6. Report

Tell the user:

- The single tag ref that was pushed
- The public workflow result: `https://github.com/eve-horizon/eve-horizon/actions`
- That deployment instances remain pinned until an owner separately approves and runs a rollout

## What Happens After Tagging

```
release-v0.1.147 pushed to eve-horizon
  -> publish-images.yml runs (builds 7 service images)
  -> pushes images to public.ecr.aws/w7c4v0w3/eve-horizon/*:0.1.147
  -> stops; a deployment instance owner chooses when to roll out
```

## Safety Notes

- Never tag from a branch other than `main` without explicit user approval
- Never tag if the working tree is dirty
- Always show the changelog and get confirmation before tagging
- Push only the intended tag ref, never all local tags
- Never treat a successful publish as proof that any cluster was upgraded
