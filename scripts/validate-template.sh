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

# Evaluate a Go template against every object in a rendered manifest. Offline:
# `annotate --local` parses and prints; it never contacts a cluster.
render_query() {
  KUBECONFIG=/dev/null kubectl annotate --local -f "$1" eve-infra/query=1 \
    -o "go-template=$2"
}

# One fact per line about the eve-registry Deployment's registry container:
# image, each command/args word, each mount, the config volume and its files.
# shellcheck disable=SC2016  # a Go template, not shell
readonly REGISTRY_FACTS='{{if and (eq .kind "Deployment") (eq .metadata.name "eve-registry")}}
{{- range .spec.template.spec.containers}}{{if eq .name "registry"}}image {{.image}}
{{range .command}}arg {{.}}
{{end}}{{range .args}}arg {{.}}
{{end}}{{range .volumeMounts}}mount {{.name}} {{.mountPath}} {{with .subPath}}{{.}}{{else}}-{{end}}
{{end}}{{end}}{{end}}
{{- range $v := .spec.template.spec.volumes}}{{with $v.configMap}}{{if eq .name "eve-registry-config"}}config-volume {{$v.name}} {{range .items}}{{.path}},{{else}}config.yml{{end}}
{{end}}{{end}}{{end}}{{end}}'

# Print why a rendered eve-registry would start without its token-auth config,
# or nothing when the config is where the registry reads it. Distribution v3
# reads /etc/distribution/config.yml and registry:2 /etc/docker/registry/config.yml;
# a config mounted anywhere else is ignored and the registry serves with no auth.
registry_config_problem() {
  local manifest="$1" facts kind a b c image="" config_volume="" config_files=""
  local -a args=() mounts=() provided=() files=()
  facts="$(render_query "$manifest" "$REGISTRY_FACTS")" \
    || { echo "could not parse $manifest"; return; }
  [[ -n "${facts//[[:space:]]/}" ]] || return 0

  while read -r kind a b c; do
    case "$kind" in
      image) image="$a" ;;
      arg) args+=("$a") ;;
      mount) mounts+=("$a $b $c") ;;
      config-volume) config_volume="$a"; config_files="${b%,}" ;;
    esac
  done <<<"$facts"

  if ! render_query "$manifest" '{{if and (eq .kind "ConfigMap") (eq .metadata.name "eve-registry-config")}}{{index .data "config.yml"}}{{end}}' \
    | grep -Eq '^[[:space:]]+realm:[[:space:]]*https://'; then
    echo "the eve-registry-config ConfigMap has no auth.token realm"
    return
  fi
  [[ -n "$config_volume" ]] || { echo "eve-registry mounts no eve-registry-config volume"; return; }

  local mount name path sub file reads=""
  for mount in "${mounts[@]}"; do
    read -r name path sub <<<"$mount"
    [[ "$name" == "$config_volume" ]] || continue
    if [[ "$sub" != "-" ]]; then
      provided+=("$path")
    else
      IFS=, read -ra files <<<"$config_files"
      for file in "${files[@]}"; do provided+=("${path%/}/$file"); done
    fi
  done
  [[ ${#provided[@]} -gt 0 ]] || { echo "the registry config volume is not mounted"; return; }

  if [[ ${#args[@]} -gt 0 ]]; then
    for a in "${args[@]}"; do
      if [[ "$a" == *.yml || "$a" == *.yaml ]]; then reads="$a"; fi
    done
    [[ -n "$reads" ]] || { echo "registry args '${args[*]}' name no config file"; return; }
  else
    case "$image" in
      registry:2*|*/registry:2*) reads=/etc/docker/registry/config.yml ;;
      distribution/distribution:3*|*/distribution/distribution:3*|registry:3*|*/registry:3*)
        reads=/etc/distribution/config.yml ;;
      *) echo "image '$image' has no known config path; name the config in args"; return ;;
    esac
  fi

  for file in "${provided[@]}"; do
    if [[ "$file" == "$reads" ]]; then return 0; fi
  done
  echo "registry ($image) reads $reads but its config is mounted at ${provided[*]}"
}

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

  problem="$(registry_config_problem "$rendered")"
  [[ -z "$problem" ]] || fail "$overlay render: $problem"

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
  problem="$(registry_config_problem "$upgraded_render")"
  [[ -z "$problem" ]] || fail "$overlay upgraded render: $problem"
done

# --- Eve-native registry ----------------------------------------------------

# GCP keeps the registry that build-and-deploy pushes to (registry.<domain>).
gcp_registry="$(render_query "$work_root/gcp.yaml" '{{if eq .metadata.name "eve-registry" "eve-registry-config" "eve-registry-data"}}{{.kind}}
{{end}}')"
for kind in Deployment Service Ingress ConfigMap ServiceAccount PersistentVolumeClaim; do
  grep -qx "$kind" <<<"$gcp_registry" || fail "gcp render is missing the registry $kind"
done
render_query "$work_root/gcp.yaml" '{{if and (eq .kind "Deployment") (eq .metadata.name "eve-registry")}}{{.spec.strategy.type}} {{range .spec.template.spec.volumes}}{{with .persistentVolumeClaim}}{{.claimName}}{{end}}{{end}}{{end}}' \
  | grep -qx 'Recreate eve-registry-data' \
  || fail "gcp registry must keep images on eve-registry-data and roll out with Recreate"
render_query "$work_root/gcp.yaml" '{{if and (eq .kind "ConfigMap") (eq .metadata.name "eve-registry-config")}}{{index .data "config.yml"}}{{end}}' \
  | grep -q 'rootdirectory: /var/lib/registry' \
  || fail "gcp registry config must store images on the mounted volume"
for overlay in aws-eks gcp; do
  render_query "$work_root/$overlay.yaml" '{{if and (eq .kind "Ingress") (eq .metadata.name "eve-registry")}}{{.spec.ingressClassName}} {{index .metadata.annotations "nginx.ingress.kubernetes.io/proxy-body-size"}} {{range .spec.tls}}{{.secretName}}{{end}}{{end}}' \
    | grep -qx 'nginx 0 eve-registry-tls' \
    || fail "$overlay registry ingress must be nginx with TLS and no body-size limit"
done

# The config-path guard itself must catch a registry that would run unauthenticated.
registry_fixture() {
  local image="$1" mount_path="$2" args_flow="${3:-}"
  cat <<FIXTURE
apiVersion: v1
kind: ConfigMap
metadata:
  name: eve-registry-config
data:
  config.yml: |
    auth:
      token:
        realm: https://api.eve.example.com/internal/registry/token
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: eve-registry
spec:
  selector:
    matchLabels: {app: eve-registry}
  template:
    metadata:
      labels: {app: eve-registry}
    spec:
      containers:
        - name: registry
          image: $image
${args_flow:+          args: $args_flow}
          volumeMounts:
            - name: config
              mountPath: $mount_path
      volumes:
        - name: config
          configMap:
            name: eve-registry-config
            items:
              - key: config.yml
                path: config.yml
FIXTURE
}
fixture="$work_root/registry-fixture.yaml"
expect_registry_guard() {
  local verdict="$1" label="$2" problem
  shift 2
  registry_fixture "$@" >"$fixture"
  problem="$(registry_config_problem "$fixture")"
  case "$verdict" in
    pass) [[ -z "$problem" ]] || fail "registry guard rejected $label: $problem" ;;
    fail) [[ -n "$problem" ]] || fail "registry guard accepted $label" ;;
  esac
}
expect_registry_guard fail "distribution v3 reading its default path, config elsewhere" \
  distribution/distribution:3.1.2 /etc/docker/registry
expect_registry_guard fail "args naming a file the config does not provide" \
  distribution/distribution:3.1.2 /etc/distribution '["serve", "/etc/docker/registry/config.yml"]'
expect_registry_guard fail "an unknown image without explicit args" \
  example.test/registry@sha256:0000000000000000000000000000000000000000000000000000000000000000 /etc/distribution
expect_registry_guard pass "distribution v3 with config at its default path" \
  distribution/distribution:3.1.2 /etc/distribution
expect_registry_guard pass "registry:2 with config at its default path" \
  registry:2 /etc/docker/registry
expect_registry_guard pass "explicit args naming the mounted config" \
  distribution/distribution:3.1.2 /etc/docker/registry '["serve", "/etc/docker/registry/config.yml"]'

# `eve-infra deploy` must fail unless the registry challenges for a bearer token.
# Stubs stand in for the cluster and the network; rendering stays real.
stub_bin="$work_root/stub-bin"
mkdir -p "$stub_bin"
real_kubectl="$(command -v kubectl)"
cat >"$stub_bin/kubectl" <<STUB
#!/usr/bin/env bash
args=()
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --kubeconfig|--context) shift 2 ;;
    *) args+=("\$1"); shift ;;
  esac
done
case "\${args[*]}" in
  kustomize\ *|annotate\ *--local*) KUBECONFIG=/dev/null exec "$real_kubectl" "\${args[@]}" ;;
  config\ *) echo eve-demo-cluster ;;
  apply\ *) cat >/dev/null ;;
  rollout\ *) exit 0 ;;
  *) echo "stub kubectl: unexpected: \${args[*]}" >&2; exit 98 ;;
esac
STUB
cat >"$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STUB_CURL_LOG"
case "${STUB_REGISTRY:-}" in
  bearer) printf 'HTTP/2 401\r\nwww-authenticate: Bearer realm="https://api.eve.example.com/internal/registry/token",service="eve-registry"\r\n\r\n' ;;
  open) printf 'HTTP/2 200\r\ncontent-length: 2\r\n\r\n' ;;
  *) echo "stub curl: no registry expected" >&2; exit 7 ;;
esac
STUB
chmod +x "$stub_bin/kubectl" "$stub_bin/curl"

deploy_with_registry() {
  local overlay="$1" registry="$2" root="$work_root/deploy-$1-$2"
  mkdir -p "$root"
  cp -R "$REPO_ROOT/bin" "$REPO_ROOT/config" "$REPO_ROOT/k8s" "$root/"
  sed -i.bak -E "s/^overlay:.*/overlay: ${overlay}/" "$root/config/platform.yaml"
  : >"$root/config/kubeconfig.yaml"
  : >"$root/curl.log"
  PATH="$stub_bin:$PATH" STUB_REGISTRY="$registry" STUB_CURL_LOG="$root/curl.log" \
    "$root/bin/eve-infra" deploy --skip-migrate </dev/null >"$root/deploy.log" 2>&1
}
for overlay in gcp aws-eks; do
  deploy_with_registry "$overlay" bearer \
    || fail "$overlay deploy failed against a registry that demands a token: $(tail -5 "$work_root/deploy-$overlay-bearer/deploy.log")"
  grep -Fq "https://registry.eve.example.com/v2/" "$work_root/deploy-$overlay-bearer/curl.log" \
    || fail "$overlay deploy did not probe the registry ingress host"
  if deploy_with_registry "$overlay" open; then
    fail "$overlay deploy passed against a registry that accepts anonymous pushes"
  fi
done
deploy_with_registry aws none \
  || fail "aws deploy should skip the registry check: $(tail -5 "$work_root/deploy-aws-none/deploy.log")"
[[ ! -s "$work_root/deploy-aws-none/curl.log" ]] || fail "aws deploy probed a registry it does not run"

echo "Template validation passed: 3 overlays, 7 services, migration, registry auth, and scrub checks."
