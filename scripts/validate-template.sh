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
command -v python3 >/dev/null || fail "python3 is required"

# Print "<Kind>/<name>" for each rendered document containing a fixed string.
rendered_objects_mentioning() {
  awk -v needle="$2" '
    function flush() { if (hit) print kind "/" name; kind = ""; name = ""; hit = 0; meta = 0 }
    /^---$/ { flush(); next }
    /^kind: / { kind = $2 }
    /^metadata:/ { meta = 1; next }
    /^[^ ]/ { meta = 0 }
    meta && /^  name: / { name = $2 }
    index($0, needle) { hit = 1 }
    END { flush() }
  ' "$1"
}

# Outputs are printed by `terraform output -json` and readable through remote
# state, `sensitive` or not. None may carry the database password.
if git -C "$REPO_ROOT" grep -n -E 'db_password' -- 'terraform/*/outputs.tf'; then
  fail "a Terraform output exposes the database password"
fi

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

# Print the rendered document of the given kind and metadata.name.
rendered_doc() {
  local file="$1" kind="$2" name="$3"
  awk -v kind="$kind" -v name="$name" '
    /^---$/ { if (k && n) printf "%s", buf; buf = ""; k = 0; n = 0; next }
    { buf = buf $0 "\n" }
    $0 == "kind: " kind { k = 1 }
    $0 == "  name: " name { n = 1 }
    END { if (k && n) printf "%s", buf }
  ' "$file"
}

# Terraform 1.10 evaluates both operands of && and ||, so a null check there
# cannot guard a function call: `var.x != null && trimspace(var.x) != ""` fails
# when var.x is null. Guard with a conditional (`var.x == null ? ... : ...`).
if git -C "$REPO_ROOT" grep -n -E \
  '[=!]=[[:space:]]*null[[:space:]]*(&&|\|\|)[[:space:]]*[a-z_]+\(' \
  -- '*.tf'; then
  fail "Terraform guards a function call with && or || on a null check"
fi

API_ONLY_KEYS="$(python3 -c 'import runpy, sys; print(*sorted(runpy.run_path(sys.argv[1])["API_ONLY_KEYS"]))' \
  "$REPO_ROOT/scripts/render-k8s-secrets.py")"

# Template-only CI must not run, and fail, in repos created from the template;
# instance-only workflows must not run in the template.
workflows="$REPO_ROOT/.github/workflows"
awk '/^  manifests:/ { job = 1; next } /^  [a-z]/ { job = 0 } job' "$workflows/template-ci.yml" \
  | grep -Fqx "    if: github.repository == 'eve-horizon/eve-horizon-infra'" \
  || fail "template-ci.yml manifests job must run only in the canonical template"
for workflow in deploy.yml health-check.yml upgrade-check.yml; do
  grep -Fq "if: github.repository != 'eve-horizon/eve-horizon-infra'" "$workflows/$workflow" \
    || fail "$workflow must not run in the canonical template"
done

# Every ingress-nginx Helm command is pinned, and setup installs the same chart
# the deploy workflow reconciles aws-eks clusters to.
helm_commands() {
  # Join backslash-continued lines so each command is one line.
  awk '/\\$/ { sub(/\\$/, ""); line = line $0; next } { print line $0; line = "" }' "$1"
}
for file in scripts/setup.sh .github/workflows/deploy.yml; do
  helm_commands "$REPO_ROOT/$file" | grep 'helm .*ingress-nginx/ingress-nginx' | grep -v -- '--version' \
    && fail "$file installs ingress-nginx without a chart --version"
done
# shellcheck disable=SC2016 # the sed pattern matches a literal ${...}
setup_ingress_chart="$(sed -n 's/^INGRESS_NGINX_CHART_VERSION="\${INGRESS_NGINX_CHART_VERSION:-\([^}]*\)}"$/\1/p' "$REPO_ROOT/scripts/setup.sh")"
deploy_ingress_chart="$(sed -n 's/^ *INGRESS_NGINX_CHART_VERSION: *//p' "$REPO_ROOT/.github/workflows/deploy.yml")"
[[ -n "$setup_ingress_chart" && "$setup_ingress_chart" == "$deploy_ingress_chart" ]] \
  || fail "setup.sh ingress-nginx chart '$setup_ingress_chart' differs from deploy.yml '$deploy_ingress_chart'"

work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT

# Cloud SQL's own deletion protection must follow the Terraform guard, or the
# instance can still be deleted from the console, gcloud or the API.
grep -Eq '^[[:space:]]*deletion_protection_enabled[[:space:]]*=[[:space:]]*var\.deletion_protection$' \
  "$REPO_ROOT/terraform/gcp/modules/sql/main.tf" \
  || fail "Cloud SQL settings do not set deletion_protection_enabled from var.deletion_protection"

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

  # EVE-001: the API must run in production mode (bootstrap closed once an
  # admin exists; token required before that).
  rendered_doc "$rendered" Deployment eve-api \
    | grep -A1 -E '^ +- name: NODE_ENV$' \
    | grep -Eq '^ +value: "?production"?$' \
    || fail "$overlay render does not set NODE_ENV=production on eve-api"

  problem="$(registry_config_problem "$rendered")"
  [[ -z "$problem" ]] || fail "$overlay render: $problem"

  # The orchestrator sends an org's work to the agent runtime pod that owns its
  # shard, by pod name, through EVE_AGENT_RUNTIME_URLS. Every replica the
  # overlay runs must be in that map, or work routed to it fails.
  runtime_replicas="$(awk '
    /^---$/ { kind = ""; name = "" }
    /^kind: / { kind = $2 }
    /^  name: / { name = $2 }
    kind == "StatefulSet" && name == "eve-agent-runtime" && /^  replicas: / { print $2; exit }
  ' "$rendered")"
  [[ "$runtime_replicas" =~ ^[0-9]+$ ]] \
    || fail "$overlay render sets no replica count on eve-agent-runtime"
  runtime_urls="$(awk '
    /- name: EVE_AGENT_RUNTIME_URLS$/ { grab = 1; next }
    grab && /^[[:space:]]*(- |[A-Za-z_]+:)/ && !/^[[:space:]]*value:/ { exit }
    grab { print }
  ' "$rendered")"
  for ((replica = 0; replica < runtime_replicas; replica++)); do
    grep -Fq "eve-agent-runtime-${replica}=" <<<"$runtime_urls" \
      || fail "$overlay runs eve-agent-runtime-${replica} but EVE_AGENT_RUNTIME_URLS does not map it"
  done

  # `eve-infra secrets sync` owns eve-app and eve-api-keys; a deploy must not
  # overwrite them. Only the API may load eve-api-keys or its keys.
  if rendered_objects_mentioning "$rendered" "kind: " | grep -Eqx 'Secret/(eve-app|eve-api-keys)'; then
    fail "$overlay render would overwrite a secret that secrets sync owns"
  fi
  rendered_objects_mentioning "$rendered" "eve-api-keys" | grep -qx 'Deployment/eve-api' \
    || fail "$overlay: eve-api does not load eve-api-keys"
  for needle in eve-api-keys $API_ONLY_KEYS; do
    holders="$(rendered_objects_mentioning "$rendered" "$needle" | grep -vx 'Deployment/eve-api' || true)"
    [[ -z "$holders" ]] || fail "$overlay: $needle reaches more than the API: $holders"
  done

  # The template ships placeholders, so deploying it unfilled must be refused.
  if "$REPO_ROOT/scripts/check-placeholders.sh" "$rendered" 2>/dev/null; then
    fail "$overlay render carries placeholders that check-placeholders.sh did not report"
  fi

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

for deployment in eve-api eve-orchestrator; do
  [[ "$(resource_doc Deployment "$deployment" "$gcp_render" | env_value EVE_DB_SNAPSHOT_BUCKET)" == "INSTANCE_PREFIX-eve-db-snapshots" ]] \
    || fail "gcp $deployment must set EVE_DB_SNAPSHOT_BUCKET=INSTANCE_PREFIX-eve-db-snapshots"
done

bucket_settings=0
while read -r bucket_setting; do
  [[ "$bucket_setting" == INSTANCE_PREFIX-eve-* ]] \
    || fail "gcp bucket setting '$bucket_setting' is outside INSTANCE_PREFIX-eve-*, where Eve's GSAs have no access"
  bucket_settings=$((bucket_settings + 1))
done < <(
  grep -A1 -E '^ *- name: EVE_(STORAGE_[A-Z_]*BUCKET[A-Z_]*|DB_SNAPSHOT_BUCKET)$' "$gcp_render" \
    | sed -n 's/^ *value: //p' | tr -d '"'
)
((bucket_settings >= 6)) || fail "gcp render lost its storage bucket settings"

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
  cp -R "$REPO_ROOT/bin" "$REPO_ROOT/config" "$REPO_ROOT/k8s" "$REPO_ROOT/scripts" "$root/"
  sed -i.bak -E "s/^overlay:.*/overlay: ${overlay}/" "$root/config/platform.yaml"
  : >"$root/config/kubeconfig.yaml"
  : >"$root/curl.log"
  # The unfilled template overlay carries placeholders (the probed host is the
  # template's registry.eve.example.com), so let deploy past that guard here.
  PATH="$stub_bin:$PATH" STUB_REGISTRY="$registry" STUB_CURL_LOG="$root/curl.log" \
    EVE_ALLOW_PLACEHOLDERS=1 \
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

# GCP org filesystem profiles (k8s/overlays/gcp/org-fs/). The default puts a
# 100 GiB Filestore share on the VPC Terraform creates; Filestore cannot reach
# a "default" network there, and a bare 5Gi claim can provision 1 TiB.
gcp_render="$work_root/gcp.yaml"
grep -Fxq '  network: INSTANCE_PREFIX-vpc' "$gcp_render" \
  || fail "gcp Filestore StorageClass is not on the <name_prefix>-vpc network"
grep -Fxq '  storageClassName: filestore-rwx' "$gcp_render" \
  || fail "gcp org filesystem claim does not use Filestore by default"
grep -Fxq '      storage: 100Gi' "$gcp_render" \
  || fail "gcp org filesystem claim does not request 100Gi of Filestore"

# The "disk" profile: one RWO disk, no Filestore, agent runtimes on one node.
disk_root="$work_root/gcp-org-fs-disk"
mkdir -p "$disk_root"
cp -R "$REPO_ROOT/k8s" "$disk_root/"
sed -i.bak -E \
  -e '/^  - org-fs\/filestore/d' \
  -e 's|^  # - org-fs/disk|  - org-fs/disk|' \
  "$disk_root/k8s/overlays/gcp/kustomization.yaml"
disk_render="$work_root/gcp-org-fs-disk.yaml"
kubectl kustomize "$disk_root/k8s/overlays/gcp" >"$disk_render"
grep -Fxq '  storageClassName: standard-rwo' "$disk_render" \
  || fail "gcp disk profile does not put the org filesystem on standard-rwo"
if grep -Eq 'ReadWriteMany|name: filestore-rwx' "$disk_render"; then
  fail "gcp disk profile still renders Filestore or a ReadWriteMany claim"
fi
grep -Fxq '            topologyKey: kubernetes.io/hostname' "$disk_render" \
  || fail "gcp disk profile does not keep agent runtimes on one node"

python3 -m unittest discover -q -s "$REPO_ROOT/tests" || fail "Python tests failed"

echo "Template validation passed: 3 overlays, 7 services, migration, GCP storage identity, registry auth, and scrub checks."
