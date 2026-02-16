#!/usr/bin/env bash
# =============================================================================
# Eve Horizon -- First-Time Cluster Setup
# =============================================================================
#
# Run this script once after Terraform provisions the server and k3s is ready.
# It installs cluster-level prerequisites that live outside the per-deploy
# kustomize manifests.
#
# Prerequisites:
#   - config/kubeconfig.yaml configured to reach your target cluster
#   - helm v3 installed (for cert-manager)
#   - config/secrets.env populated (see config/secrets.env.example)
#
# Usage:
#   ./scripts/setup.sh
#
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_FILE="$REPO_ROOT/config/secrets.env"
KUBECONFIG_FILE="$REPO_ROOT/config/kubeconfig.yaml"

NAMESPACE="eve"
CONFIG_FILE="$REPO_ROOT/config/platform.yaml"

# Read cloud provider from platform.yaml
CLOUD="$(sed -n 's/^cloud: *//p' "$CONFIG_FILE" | head -1 | tr -d '"' | tr -d "'")"
CLOUD="${CLOUD:-aws}"
REGION="$(sed -n 's/^region: *//p' "$CONFIG_FILE" | head -1 | tr -d '"' | tr -d "'")"
REGION="${REGION:-us-west-2}"
COMPUTE_MODEL="$(sed -n '/^compute:/,/^[^ ]/{s/^  model: *//p;}' "$CONFIG_FILE" | head -1 | sed 's/[[:space:]]*#.*$//' | tr -d '"' | tr -d "'" | xargs)"
COMPUTE_MODEL="${COMPUTE_MODEL:-k3s}"
NAME_PREFIX="$(sed -n 's/^name_prefix: *//p' "$CONFIG_FILE" | head -1 | sed 's/[[:space:]]*#.*$//' | tr -d '"' | tr -d "'" | xargs)"
NAME_PREFIX="${NAME_PREFIX:-eve}"
REGISTRY="$(sed -n '/^platform:/,/^[^ ]/{s/^  registry: *//p;}' "$CONFIG_FILE" | head -1 | sed 's/[[:space:]]*#.*$//' | tr -d '"' | tr -d "'" | xargs)"
REGISTRY="${REGISTRY:-public.ecr.aws/w7c4v0w3/eve-horizon}"
REGISTRY_HOST="${REGISTRY%%/*}"

# Colors
if [[ -t 1 ]]; then
  BOLD='\033[1m' GREEN='\033[0;32m' CYAN='\033[0;36m' YELLOW='\033[0;33m' RED='\033[0;31m' RESET='\033[0m'
else
  BOLD='' GREEN='' CYAN='' YELLOW='' RED='' RESET=''
fi

info() { echo -e "${CYAN}=>${RESET} $*"; }
ok()   { echo -e "${GREEN}OK${RESET} $*"; }
warn() { echo -e "${YELLOW}Warning:${RESET} $*" >&2; }
die()  { echo -e "${RED}Error:${RESET} $*" >&2; exit 1; }

resolve_kubeconfig() {
  if [[ ! -f "$KUBECONFIG_FILE" ]]; then
    if [[ "$CLOUD" == "aws" && "$COMPUTE_MODEL" == "eks" ]]; then
      die "Missing kubeconfig: $KUBECONFIG_FILE
Generate it with:
  ./bin/eve-infra kubeconfig refresh
Then verify with:
  ./bin/eve-infra kubeconfig doctor"
    fi
    die "Missing kubeconfig: $KUBECONFIG_FILE
Create config/kubeconfig.yaml for this deployment, then verify with:
  ./bin/eve-infra kubeconfig doctor"
  fi

  if [[ -n "${KUBECONFIG:-}" && "$KUBECONFIG" != "$KUBECONFIG_FILE" ]]; then
    warn "Ignoring external KUBECONFIG='$KUBECONFIG' and using canonical '$KUBECONFIG_FILE'."
  fi
  export KUBECONFIG="$KUBECONFIG_FILE"
}

assert_safe_kube_context() {
  if [[ "${EVE_KUBE_GUARD_BYPASS:-0}" == "1" ]]; then
    warn "Bypassing kube context guard (EVE_KUBE_GUARD_BYPASS=1)."
    return
  fi

  local ctx expected_cluster
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  [[ -n "$ctx" ]] || die "kubectl has no current context configured."

  expected_cluster="${NAME_PREFIX}-cluster"

  if [[ "$CLOUD" == "aws" && "$COMPUTE_MODEL" == "eks" ]]; then
    if [[ "$ctx" != *":cluster/${expected_cluster}" && "$ctx" != "$expected_cluster" ]]; then
      die "Unsafe kube context '$ctx' for aws/eks. Expected context for '${expected_cluster}'.
Switch context first or intentionally override with EVE_KUBE_GUARD_BYPASS=1."
    fi
  elif [[ "$ctx" == arn:aws:eks:* || "$ctx" == *":cluster/"* ]]; then
    die "Unsafe kube context '$ctx' for cloud='$CLOUD' compute.model='$COMPUTE_MODEL'.
Switch context first or intentionally override with EVE_KUBE_GUARD_BYPASS=1."
  fi

  info "Using kube context: ${ctx}"
}
echo ""
echo -e "${BOLD}Eve Horizon -- First-Time Cluster Setup${RESET}"
echo ""

resolve_kubeconfig
assert_safe_kube_context

# -------------------------------------------------------------------------
# 1. Create namespace
# -------------------------------------------------------------------------
info "Creating namespace '${NAMESPACE}'..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
ok "Namespace '${NAMESPACE}' exists."

# -------------------------------------------------------------------------
# 2. Install nginx-ingress (GCP only — GKE does not include Traefik)
# -------------------------------------------------------------------------
if [ "$CLOUD" = "gcp" ]; then
  info "Installing nginx-ingress controller (GKE)..."
  if kubectl get namespace ingress-nginx &>/dev/null; then
    ok "ingress-nginx namespace already exists, skipping install."
  else
    if ! command -v helm &>/dev/null; then
      die "helm is required to install nginx-ingress. Install it first:
  https://helm.sh/docs/intro/install/"
    fi

    # Get ingress IP from terraform output if available
    INGRESS_IP="$(terraform -chdir="$REPO_ROOT/terraform/gcp" output -raw ingress_ip 2>/dev/null || true)"

    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
    helm repo update

    helm install ingress-nginx ingress-nginx/ingress-nginx \
      --namespace ingress-nginx --create-namespace \
      ${INGRESS_IP:+--set controller.service.loadBalancerIP="$INGRESS_IP"} \
      --wait

    ok "nginx-ingress installed."
  fi
fi

# -------------------------------------------------------------------------
# 3. Install cert-manager (for TLS via Let's Encrypt)
# -------------------------------------------------------------------------
info "Installing cert-manager..."
if kubectl get namespace cert-manager &>/dev/null; then
  ok "cert-manager namespace already exists, skipping install."
else
  if ! command -v helm &>/dev/null; then
    die "helm is required to install cert-manager. Install it first:
  https://helm.sh/docs/intro/install/"
  fi

  helm repo add jetstack https://charts.jetstack.io --force-update
  helm repo update

  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version v1.17.1 \
    --set crds.enabled=true \
    --wait

  ok "cert-manager installed."
fi

# -------------------------------------------------------------------------
# 3. Create ClusterIssuers for Let's Encrypt
# -------------------------------------------------------------------------
# Determine ingress class for ACME solver
if [ "$CLOUD" = "gcp" ]; then
  INGRESS_CLASS="nginx"
else
  INGRESS_CLASS="traefik"
fi

info "Creating Let's Encrypt ClusterIssuers..."

# Read TLS email from platform.yaml (simple grep)
TLS_EMAIL="$(sed -n '/^tls:/,/^[^ ]/{s/^  email: *"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p;}' "$REPO_ROOT/config/platform.yaml" | head -1)"
if [[ -z "$TLS_EMAIL" || "$TLS_EMAIL" == "ops@example.com" ]]; then
  warn "tls.email is not configured in config/platform.yaml. Using placeholder."
  TLS_EMAIL="ops@example.com"
fi

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${TLS_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - http01:
          ingress:
            class: ${INGRESS_CLASS}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${TLS_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            class: ${INGRESS_CLASS}
EOF

ok "ClusterIssuers created."

# -------------------------------------------------------------------------
# 4. Create container registry pull secret (if required)
# -------------------------------------------------------------------------
info "Configuring registry pull secret for '${REGISTRY}'..."

if [[ "$REGISTRY_HOST" == "public.ecr.aws" ]]; then
  ok "Registry '${REGISTRY}' is public. Skipping eve-registry pull secret."
elif [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck disable=SC1090
  set +u
  source "$SECRETS_FILE"
  set -u

  REGISTRY_USER="${REGISTRY_USERNAME:-}"
  REGISTRY_PASS="${REGISTRY_PASSWORD:-}"

  if [[ "$REGISTRY_HOST" == "ghcr.io" ]]; then
    REGISTRY_USER="${REGISTRY_USER:-${GHCR_USERNAME:-}}"
    REGISTRY_PASS="${REGISTRY_PASS:-${GHCR_TOKEN:-}}"
  elif [[ "$REGISTRY_HOST" == *.dkr.ecr.*.amazonaws.com ]]; then
    # Allow explicit credentials override, otherwise derive an auth token from
    # local AWS credentials for private ECR registries.
    if [[ -z "$REGISTRY_USER" || -z "$REGISTRY_PASS" ]] && command -v aws &>/dev/null; then
      REGISTRY_USER="AWS"
      REGISTRY_PASS="$(aws ecr get-login-password --region "$REGION" 2>/dev/null || true)"
    fi
  fi

  if [[ -n "$REGISTRY_USER" && -n "$REGISTRY_PASS" ]]; then
    kubectl create secret docker-registry eve-registry \
      --docker-server="$REGISTRY_HOST" \
      --docker-username="$REGISTRY_USER" \
      --docker-password="$REGISTRY_PASS" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f -
    ok "Registry secret 'eve-registry' created for ${REGISTRY_HOST}."
  else
    warn "No pull credentials resolved for registry '${REGISTRY_HOST}'. Skipping eve-registry secret."
    echo "  For private registries, set one of the following in config/secrets.env:"
    echo "    - REGISTRY_USERNAME + REGISTRY_PASSWORD (generic)"
    echo "    - GHCR_USERNAME + GHCR_TOKEN (for ghcr.io)"
  fi
else
  warn "config/secrets.env not found. Skipping registry secret."
  echo "  Copy the example and fill in your values:"
  echo "    cp config/secrets.env.example config/secrets.env"
fi

# -------------------------------------------------------------------------
# 5. Sync application secrets
# -------------------------------------------------------------------------
info "Syncing application secrets..."
if [[ -f "$SECRETS_FILE" ]]; then
  kubectl create secret generic eve-app \
    --from-env-file="$SECRETS_FILE" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  ok "Secret 'eve-app' created."
else
  warn "Skipping (no secrets.env file)."
fi

# -------------------------------------------------------------------------
# Done
# -------------------------------------------------------------------------
echo ""
echo -e "${BOLD}Setup complete.${RESET}"
echo ""
echo "Next steps:"
echo "  1. Verify config:     cat config/platform.yaml"
echo "  2. Deploy platform:   bin/eve-infra deploy"
echo "  3. Run migrations:    bin/eve-infra db migrate"
echo "  4. Check health:      bin/eve-infra health"
echo ""
