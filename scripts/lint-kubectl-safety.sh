#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

MUTATING_RE='(^|[[:space:]])kubectl[[:space:]]+(apply|patch|delete|replace|rollout|scale|annotate|label|set|create)([^[:alnum:]_-]|$)'
SAFE_ENTRYPOINT_RE='^(bin/eve-infra|scripts/setup\.sh|\.github/workflows/deploy\.yml):'

matches="$(grep -RInE "$MUTATING_RE" bin scripts .github/workflows || true)"
violations="$(printf '%s\n' "$matches" | grep -Ev "$SAFE_ENTRYPOINT_RE" || true)"

if [[ -n "$violations" ]]; then
  echo "Unsafe mutating kubectl usage found outside approved entrypoints:"
  printf '%s\n' "$violations"
  exit 1
fi

if ! grep -Eq "assert_safe_kube_context|require_cluster_access" bin/eve-infra; then
  echo "Missing kube context guard in bin/eve-infra"
  exit 1
fi

if ! grep -Eq "assert_safe_kube_context" scripts/setup.sh; then
  echo "Missing kube context guard in scripts/setup.sh"
  exit 1
fi

echo "kubectl safety lint passed."
