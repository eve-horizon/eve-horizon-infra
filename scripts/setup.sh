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
#   - kubectl configured to reach your cluster (KUBECONFIG set or default)
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

echo ""
echo -e "${BOLD}Eve Horizon -- First-Time Cluster Setup${RESET}"
echo ""

# -------------------------------------------------------------------------
# 1. Create namespace
# -------------------------------------------------------------------------
info "Creating namespace '${NAMESPACE}'..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
ok "Namespace '${NAMESPACE}' exists."

# -------------------------------------------------------------------------
# 2. Install cert-manager (for TLS via Let's Encrypt)
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
            class: traefik
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
            class: traefik
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
