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
#   - kubectl configured to reach your target cluster
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

NAMESPACE="eve"
CONFIG_FILE="$REPO_ROOT/config/platform.yaml"

# Read cloud provider from platform.yaml
CLOUD="$(sed -n 's/^cloud: *//p' "$CONFIG_FILE" | head -1 | tr -d '"' | tr -d "'")"
CLOUD="${CLOUD:-aws}"
OVERLAY="$(sed -n 's/^overlay: *//p' "$CONFIG_FILE" | head -1 | tr -d '"' | tr -d "'")"
OVERLAY="${OVERLAY:-$CLOUD}"
REGION="$(sed -n 's/^region: *//p' "$CONFIG_FILE" | head -1 | tr -d '"' | tr -d "'")"
REGION="${REGION:-us-west-2}"
COMPUTE_MODEL="$(sed -n '/^compute:/,/^[^ ]/{s/^  model: *//p;}' "$CONFIG_FILE" | head -1 | sed 's/[[:space:]]*#.*$//' | tr -d '"' | tr -d "'" | xargs)"
COMPUTE_MODEL="${COMPUTE_MODEL:-k3s}"
NAME_PREFIX="$(sed -n 's/^name_prefix: *//p' "$CONFIG_FILE" | head -1 | sed 's/[[:space:]]*#.*$//' | tr -d '"' | tr -d "'" | xargs)"
NAME_PREFIX="${NAME_PREFIX:-eve}"

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

assert_safe_kube_context

# -------------------------------------------------------------------------
# 1. Create namespace
# -------------------------------------------------------------------------
info "Creating namespace '${NAMESPACE}'..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
ok "Namespace '${NAMESPACE}' exists."

# -------------------------------------------------------------------------
# 2. Install nginx-ingress when required by overlay
# -------------------------------------------------------------------------
if [ "$CLOUD" = "gcp" ] || [ "$OVERLAY" = "aws-eks" ]; then
  info "Installing nginx-ingress controller..."
  if kubectl get namespace ingress-nginx &>/dev/null; then
    ok "ingress-nginx namespace already exists, skipping install."
  else
    if ! command -v helm &>/dev/null; then
      die "helm is required to install nginx-ingress. Install it first:
  https://helm.sh/docs/intro/install/"
    fi

    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
    helm repo update

    if [ "$CLOUD" = "gcp" ]; then
      # Get ingress IP from terraform output if available
      INGRESS_IP="$(terraform -chdir="$REPO_ROOT/terraform/gcp" output -raw ingress_ip 2>/dev/null || true)"
      helm install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx --create-namespace \
        ${INGRESS_IP:+--set controller.service.loadBalancerIP="$INGRESS_IP"} \
        --wait
    else
      helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx --create-namespace \
        --set controller.service.type=LoadBalancer \
        --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=nlb \
        --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"=internet-facing \
        --wait
    fi

    ok "nginx-ingress installed."
  fi
fi

# -------------------------------------------------------------------------
# 2b. Install Cluster Autoscaler (AWS EKS overlay)
# -------------------------------------------------------------------------
if [ "$OVERLAY" = "aws-eks" ]; then
  info "Installing Cluster Autoscaler..."

  if ! command -v helm &>/dev/null; then
    die "helm is required to install cluster-autoscaler. Install it first:
  https://helm.sh/docs/intro/install/"
  fi

  CLUSTER_NAME="$(terraform -chdir="$REPO_ROOT/terraform/aws" output -raw cluster_name 2>/dev/null || true)"
  AUTOSCALER_ROLE_ARN="$(terraform -chdir="$REPO_ROOT/terraform/aws" output -raw cluster_autoscaler_irsa_role_arn 2>/dev/null || true)"

  if [[ -z "$CLUSTER_NAME" || -z "$AUTOSCALER_ROLE_ARN" ]]; then
    warn "Could not resolve cluster_name/cluster_autoscaler_irsa_role_arn from terraform outputs. Skipping Cluster Autoscaler install."
  else
    helm repo add autoscaler https://kubernetes.github.io/autoscaler --force-update
    helm repo update

    helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
      --namespace kube-system --create-namespace \
      --set cloudProvider=aws \
      --set autoDiscovery.clusterName="$CLUSTER_NAME" \
      --set awsRegion="$REGION" \
      --set image.tag=v1.31.0 \
      --set rbac.serviceAccount.create=true \
      --set rbac.serviceAccount.name=cluster-autoscaler \
      --set rbac.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$AUTOSCALER_ROLE_ARN" \
      --wait

    ok "Cluster Autoscaler installed."
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
if [ "$CLOUD" = "gcp" ] || [ "$OVERLAY" = "aws-eks" ]; then
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
# 4. Create container registry pull secret
# -------------------------------------------------------------------------
info "Creating registry pull secret..."

if [[ -f "$SECRETS_FILE" ]]; then
  # Source secrets to get GHCR credentials
  # shellcheck disable=SC1090
  set +u
  source "$SECRETS_FILE"
  set -u

  if [[ -n "${GHCR_USERNAME:-}" && -n "${GHCR_TOKEN:-}" ]]; then
    kubectl create secret docker-registry eve-registry \
      --docker-server=ghcr.io \
      --docker-username="$GHCR_USERNAME" \
      --docker-password="$GHCR_TOKEN" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f -
    ok "Registry secret 'eve-registry' created."
  else
    warn "GHCR_USERNAME or GHCR_TOKEN not set in secrets.env. Skipping registry secret."
    echo "  Create it manually:"
    echo "    kubectl create secret docker-registry eve-registry \\"
    echo "      --docker-server=ghcr.io \\"
    echo "      --docker-username=<your-username> \\"
    echo "      --docker-password=<your-token> \\"
    echo "      -n $NAMESPACE"
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
# 6. Sync registry signing cert (required for aws-eks registry overlay)
# -------------------------------------------------------------------------
if [ "$OVERLAY" = "aws-eks" ]; then
  REGISTRY_SIGNING_CERT_PATH="${REGISTRY_SIGNING_CERT_PATH:-/tmp/registry-signing.crt}"
  if [[ -f "$REGISTRY_SIGNING_CERT_PATH" ]]; then
    info "Syncing registry signing cert secret..."
    kubectl create secret generic eve-registry-cert \
      --from-file=cert.pem="$REGISTRY_SIGNING_CERT_PATH" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f -
    ok "Secret 'eve-registry-cert' created."
  else
    warn "Registry signing cert not found at ${REGISTRY_SIGNING_CERT_PATH}. Skipping eve-registry-cert secret."
  fi
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
