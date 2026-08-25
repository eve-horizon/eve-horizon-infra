#!/usr/bin/env bash
# Validate the public template without cluster credentials or instance state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

readonly REGISTRY="public.ecr.aws/w7c4v0w3/eve-horizon"
readonly SENTINEL_VERSION="9.9.999-template-ci"
readonly OVERLAYS=(aws aws-eks gcp)
readonly SERVICES=(api sso gateway agent-runtime orchestrator worker dashboard)

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

command -v git >/dev/null || fail "git is required"
command -v kubectl >/dev/null || fail "kubectl with Kustomize v5 is required"

if git -C "$REPO_ROOT" grep -n -I -i -E \
  'corf\.ai|corfai|api\.eh1\.incept5\.dev|org_Incept5|proj_[0-9a-z]{10,}|user_[0-9a-z]{10,}' \
  -- . ':(exclude)scripts/validate-template.sh'; then
  fail "template contains instance-specific domains, IDs, or names"
fi

work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT

for overlay in "${OVERLAYS[@]}"; do
  rendered="$work_root/${overlay}.yaml"
  kubectl kustomize "$REPO_ROOT/k8s/overlays/$overlay" >"$rendered"

  for service in "${SERVICES[@]}"; do
    grep -Eq "image: .*eve-horizon/${service}:" "$rendered" \
      || fail "$overlay render is missing the $service service image"
  done

  upgrade_root="$work_root/upgrade-$overlay"
  mkdir -p "$upgrade_root"
  cp -R "$REPO_ROOT/bin" "$REPO_ROOT/config" "$REPO_ROOT/k8s" "$upgrade_root/"
  sed -i.bak -E \
    "s/^overlay:.*/overlay: ${overlay}/" \
    "$upgrade_root/config/platform.yaml"
  rm -f "$upgrade_root/config/platform.yaml.bak"

  "$upgrade_root/bin/eve-infra" upgrade "$SENTINEL_VERSION" >/dev/null

  grep -Fq "version: \"$SENTINEL_VERSION\"" \
    "$upgrade_root/config/platform.yaml" \
    || fail "$overlay upgrade did not update config/platform.yaml"

  for service in "${SERVICES[@]}"; do
    grep -R -Eq \
      "image: ${REGISTRY}/${service}:${SENTINEL_VERSION}$" \
      "$upgrade_root/k8s/overlays/$overlay"/*-patch.yaml \
      || fail "$overlay upgrade did not pin $service to the sentinel version"
  done

  grep -Eq \
    "image: ${REGISTRY}/api:${SENTINEL_VERSION}$" \
    "$upgrade_root/k8s/overlays/$overlay/db-migrate-job-patch.yaml" \
    || fail "$overlay upgrade did not move the migration image"

  if grep -R -E \
    'image: .*eve-horizon/(api|sso|gateway|agent-runtime|orchestrator|worker|dashboard):(latest|staging|local)$' \
    "$upgrade_root/k8s/overlays/$overlay"/*-patch.yaml; then
    fail "$overlay upgrade left a floating platform service tag"
  fi

  upgraded_render="$work_root/${overlay}-upgraded.yaml"
  kubectl kustomize "$upgrade_root/k8s/overlays/$overlay" >"$upgraded_render"
  for service in "${SERVICES[@]}"; do
    grep -Fq "image: ${REGISTRY}/${service}:${SENTINEL_VERSION}" \
      "$upgraded_render" \
      || fail "$overlay upgraded render is missing pinned $service"
  done
done

echo "Template validation passed: 3 overlays, 7 services, migration, and scrub checks."
