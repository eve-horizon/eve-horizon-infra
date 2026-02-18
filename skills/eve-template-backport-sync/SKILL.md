---
name: eve-template-backport-sync
description: Backport reusable infra changes from this repo into ../../eve-horizon/eve-horizon-infra using direct shell commands and metadata state. Use when checking commits since last review and applying required template backports without manual approval.
---

# Eve Template Backport Sync

Use command-based backporting only. Do not use helper scripts.

## Files

- Metadata state: `skills/eve-template-backport-sync/state/backport-metadata.json`

## 1) Set Context

```bash
SOURCE_REPO="$(git rev-parse --show-toplevel)"
TEMPLATE_REPO="$SOURCE_REPO/../../eve-horizon/eve-horizon-infra"
META="$SOURCE_REPO/skills/eve-template-backport-sync/state/backport-metadata.json"
```

## 2) Guardrails

Run with clean working trees:

```bash
git -C "$SOURCE_REPO" status --short
git -C "$TEMPLATE_REPO" status --short
```

If either repo is dirty, stop and resolve first.

## 3) Determine Commit Range From Metadata

```bash
LAST_CHECKED="$(jq -r '.last_checked_commit // empty' "$META")"
if [ -n "$LAST_CHECKED" ]; then
  RANGE="$LAST_CHECKED..HEAD"
else
  RANGE="$(git rev-list --max-count=30 --reverse HEAD | head -n1)..HEAD"
fi
echo "$RANGE"
```

## 4) Classify Commits

Policy:
- `always`: `k8s/base/**`, `terraform/*/modules/**`, `bin/eve-infra`, `scripts/**`, `.github/workflows/**`, `skills/**`, `skills.txt`
- `ask`: `k8s/overlays/**`, `terraform/*/main.tf`, `terraform/*/variables.tf`, `terraform/*/outputs.tf`, docs/meta files
- `never`: instance-local config/secrets/tfvars

Backport automatically when commit matches `always` or clearly updates paths shared by the template.

## 5) Apply Backport Commits (No Approval Loop)

For each commit you classify as backport:

```bash
SHA="<source-commit-sha>"
SUBJECT="$(git show -s --format=%s "$SHA")"

while IFS= read -r SRC; do
  [ -z "$SRC" ] && continue

  # Path alias: aws-eks overlay in source -> aws overlay in template
  DEST="${SRC/k8s\/overlays\/aws-eks\//k8s/overlays/aws/}"
  DEST_PATH="$TEMPLATE_REPO/$DEST"

  # Skip obvious instance-local paths
  case "$DEST" in
    config/platform.yaml|config/secrets.env|config/kubeconfig.yaml|terraform/*/terraform.tfvars)
      continue
      ;;
  esac

  if git cat-file -e "$SHA:$SRC" 2>/dev/null; then
    mkdir -p "$(dirname "$DEST_PATH")"
    git show "$SHA:$SRC" > "$DEST_PATH"
    git -C "$TEMPLATE_REPO" add "$DEST"
  else
    # Deleted in source commit
    rm -f "$DEST_PATH"
    git -C "$TEMPLATE_REPO" add -A -- "$DEST"
  fi
done < <(git show --pretty=format: --name-only "$SHA")

if ! git -C "$TEMPLATE_REPO" diff --cached --quiet; then
  git -C "$TEMPLATE_REPO" commit -m "backport: $SUBJECT" -m "Source: incept5-eve-infra $SHA"
fi
```

## 6) Update Metadata After Backport Pass

```bash
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HEAD_SHA="$(git rev-parse HEAD)"
TMP="$(mktemp)"

jq \
  --arg head "$HEAD_SHA" \
  --arg now "$NOW" \
  '.last_checked_commit = $head
   | .last_checked_at = $now
   | .history += [{"checked_at": $now, "to_commit": $head}] 
   | .history = (.history | .[-100:])' \
  "$META" > "$TMP" && mv "$TMP" "$META"
```

## 7) Verify

```bash
git -C "$TEMPLATE_REPO" log --oneline -n 10
cat "$META"
```
