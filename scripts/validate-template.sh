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
  -- . \
  ':(exclude)scripts/validate-template.sh' \
  ':(exclude)skills/eve-template-backport-sync/SKILL.md'; then
  fail "template contains instance-specific domains, IDs, or names"
fi

work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT

for overlay in "${OVERLAYS[@]}"; do
  [[ -f "$REPO_ROOT/k8s/overlays/$overlay/db-migrate-job-patch.yaml" ]] \
    || fail "$overlay is missing its deployment migration job"
  [[ -f "$REPO_ROOT/k8s/overlays/$overlay/auth-bootstrap-job.yaml" ]] \
    || fail "$overlay is missing its deployment auth bootstrap job"

  rendered="$work_root/${overlay}.yaml"
  kubectl kustomize "$REPO_ROOT/k8s/overlays/$overlay" >"$rendered"

  for service in "${SERVICES[@]}"; do
    grep -Eq "image: .*eve-horizon/${service}:" "$rendered" \
      || fail "$overlay render is missing the $service service image"
  done

  # BuildKit runs a digest-pinned release, and its GC limits fit its cache
  # volume: MinFree + MaxUsed below the volume, Reserved below MaxUsed.
  grep -Eq '^ +image: moby/buildkit:v[0-9.]+@sha256:[0-9a-f]{64}$' "$rendered" \
    || fail "$overlay: buildkitd image is not a release pinned by digest"
  gc="$(sed -n 's/^ *- --oci-worker-gc-keepstorage=//p' "$rendered")"
  cache_size="$(awk '
    function flush() { if (kind == "PersistentVolumeClaim" && name == "buildkitd-cache") print size; kind = name = size = "" }
    /^---$/ { flush(); next }
    /^kind: / { kind = $2 }
    /^  name: / { name = $2 }
    /^ +storage: / { size = $2 }
    END { flush() }' "$rendered")"
  [[ "$cache_size" =~ ^([0-9]+)Gi$ ]] || fail "$overlay: unexpected buildkitd-cache size '$cache_size'"
  cache_mb=$((BASH_REMATCH[1] * 1024))
  IFS=, read -r gc_reserved gc_free gc_max <<<"$gc"
  [[ "$gc_reserved" =~ ^[0-9]+$ && "$gc_free" =~ ^[0-9]+$ && "$gc_max" =~ ^[0-9]+$ ]] \
    || fail "$overlay: buildkitd GC must be Reserved,MinFree,MaxUsed in MB, got '$gc'"
  ((gc_reserved < gc_max && gc_free + gc_max < cache_mb)) \
    || fail "$overlay: buildkitd GC ($gc MB) does not fit its $cache_size cache volume"

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
