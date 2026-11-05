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

# Print one rendered resource, selected by kind and metadata.name.
resource_doc() {
  awk -v kind="$1" -v name="$2" '
    function flush() {
      if (doc_kind == kind && doc_name == name) printf "%s", doc
      doc = ""; doc_kind = ""; doc_name = ""; in_metadata = 0
    }
    /^---$/ { flush(); next }
    { doc = doc $0 "\n" }
    /^kind: / { doc_kind = $2 }
    /^metadata:/ { in_metadata = 1; next }
    /^[^ ]/ { in_metadata = 0 }
    in_metadata && /^  name: / && doc_name == "" { doc_name = $2 }
    END { flush() }
  ' "$3"
}

# Print the literal value of a container env var in the resource on stdin.
env_value() {
  awk -v env="$1" '
    $0 ~ ("- name: " env "$") { found = 1; next }
    found && /^ *value: / { sub(/^ *value: /, ""); gsub(/"/, ""); print; exit }
    found { exit }
  '
}

# GCP storage identity: the overlay must match terraform/gcp/modules/storage,
# whose IAM only covers buckets named INSTANCE_PREFIX-eve-*. agent-runtime
# runs agent code, so it holds its own read-only GSA, never the platform one.
gcp_render="$work_root/gcp.yaml"
gke_gsa() {
  resource_doc ServiceAccount "$1" "$gcp_render" \
    | sed -n 's/^ *iam\.gke\.io\/gcp-service-account: //p'
}

[[ "$(gke_gsa eve-agent-runtime)" == "INSTANCE_PREFIX-eve-agents@GCP_PROJECT.iam.gserviceaccount.com" ]] \
  || fail "gcp eve-agent-runtime must use its own GSA (INSTANCE_PREFIX-eve-agents), not the platform storage GSA"
for ksa in eve-api eve-worker eve-orchestrator; do
  [[ "$(gke_gsa "$ksa")" == "INSTANCE_PREFIX-eve-storage@GCP_PROJECT.iam.gserviceaccount.com" ]] \
    || fail "gcp $ksa must use the platform storage GSA"
done

gcp_worker="$(resource_doc Deployment eve-worker "$gcp_render")"
[[ "$(env_value EVE_STORAGE_ORG_BUCKET_PREFIX <<<"$gcp_worker")" == "INSTANCE_PREFIX-eve-org" ]] \
  || fail "gcp worker must set EVE_STORAGE_ORG_BUCKET_PREFIX=INSTANCE_PREFIX-eve-org"
[[ "$(env_value EVE_STORAGE_APP_BUCKET_PREFIX <<<"$gcp_worker")" == "INSTANCE_PREFIX-eve-app" ]] \
  || fail "gcp worker must set EVE_STORAGE_APP_BUCKET_PREFIX=INSTANCE_PREFIX-eve-app, apart from org buckets"

bucket_settings=0
while read -r bucket_setting; do
  [[ "$bucket_setting" == INSTANCE_PREFIX-eve-* ]] \
    || fail "gcp bucket setting '$bucket_setting' is outside INSTANCE_PREFIX-eve-*, where Eve's GSAs have no access"
  bucket_settings=$((bucket_settings + 1))
done < <(
  grep -A1 -E '^ *- name: EVE_(STORAGE_[A-Z_]*BUCKET[A-Z_]*|DB_SNAPSHOT_BUCKET)$' "$gcp_render" \
    | sed -n 's/^ *value: //p' | tr -d '"'
)
((bucket_settings >= 4)) || fail "gcp render lost its storage bucket settings"

echo "Template validation passed: 3 overlays, 7 services, migration, GCP storage identity, and scrub checks."
