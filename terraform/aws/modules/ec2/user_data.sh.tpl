#!/bin/bash
set -euo pipefail

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "=== Eve Horizon k3s Bootstrap ==="

# System updates
apt-get update
apt-get upgrade -y
apt-get install -y curl jq git

# Install k3s
curl -sfL https://get.k3s.io | sh -

# Wait for k3s
echo "Waiting for k3s to be ready..."
until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
  sleep 5
done
echo "k3s is ready!"

# Set kubeconfig permissions
chmod 644 /etc/rancher/k3s/k3s.yaml

# Create eve namespace
kubectl create namespace eve --dry-run=client -o yaml | kubectl apply -f -

# Store configuration
cat > /opt/eve-horizon-config.env << 'EOF'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export DATABASE_URL="${database_url}"
export DOMAIN="${domain}"
EOF

echo "=== Bootstrap complete ==="
