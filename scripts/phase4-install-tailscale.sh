#!/bin/bash
set -euo pipefail

# Phase 4: Install Tailscale Operator

echo "=== Phase 4: Tailscale Integration ==="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Check kubectl access
if ! kubectl get nodes &>/dev/null; then
    echo -e "${RED}Cannot access Kubernetes cluster!${NC}"
    echo "Make sure kubeconfig is set:"
    echo "  export KUBECONFIG=~/.kube/pedro-ops-config"
    exit 1
fi

# Check for OAuth credentials
if [ -z "${TS_CLIENT_ID:-}" ] || [ -z "${TS_CLIENT_SECRET:-}" ]; then
    echo -e "${RED}Tailscale OAuth credentials not set!${NC}"
    echo ""
    echo "Please set environment variables:"
    echo "  export TS_CLIENT_ID='your_client_id'"
    echo "  export TS_CLIENT_SECRET='your_client_secret'"
    echo ""
    echo "Get credentials from: https://login.tailscale.com/admin/settings/oauth"
    exit 1
fi

# Add Tailscale Helm repository
echo "[1/6] Adding Tailscale Helm repository..."
helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm repo update
echo -e "${GREEN}✓ Helm repository added${NC}"
echo ""

# Create namespace
echo "[2/6] Creating Tailscale namespace..."
kubectl apply -f k8s/tailscale/namespace.yaml
echo -e "${GREEN}✓ Namespace created${NC}"
echo ""

# Install Tailscale operator
echo "[3/6] Installing Tailscale operator..."
helm install tailscale-operator tailscale/tailscale-operator \
  --namespace tailscale \
  --set oauth.clientId="$TS_CLIENT_ID" \
  --set oauth.clientSecret="$TS_CLIENT_SECRET"

echo -e "${GREEN}✓ Operator installed${NC}"
echo ""

# Wait for operator to be ready
echo "[4/6] Waiting for operator to be ready..."
kubectl wait --for=condition=ready pod -l app=tailscale-operator -n tailscale --timeout=120s
echo -e "${GREEN}✓ Operator is ready${NC}"
echo ""

# Deploy connector
echo "[5/6] Deploying Tailscale connector..."
kubectl apply -f k8s/tailscale/connector.yaml
echo -e "${GREEN}✓ Connector deployed${NC}"
echo ""

# Deploy DNS config
echo "[6/6] Deploying DNS configuration..."
kubectl apply -f k8s/tailscale/dns-config.yaml

# Wait for nameserver
echo "Waiting for nameserver to be ready..."
sleep 10
kubectl wait --for=condition=ready pod -l app=tailscale-nameserver -n tailscale --timeout=120s || true

echo -e "${GREEN}✓ DNS configuration deployed${NC}"
echo ""

# Get Tailscale DNS service IP
TS_DNS_IP=$(kubectl get svc -n tailscale tailscale-nameserver -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "Not ready yet")

echo ""
echo -e "${GREEN}=== Tailscale Integration Complete ===${NC}"
echo ""
echo "Tailscale Operator Status:"
kubectl get pods -n tailscale
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo ""
echo "1. Approve connector routes in Tailscale admin console:"
echo "   https://login.tailscale.com/admin/machines"
echo "   Look for 'pedro-ops-cluster' connector and approve advertised routes"
echo ""
echo "2. Configure CoreDNS for .ts.net resolution:"
echo "   Tailscale DNS Service IP: $TS_DNS_IP"
echo ""
echo "   kubectl edit configmap coredns -n kube-system"
echo ""
echo "   Add this block to the Corefile:"
echo "   ts.net:53 {"
echo "     errors"
echo "     cache 30"
echo "     forward . $TS_DNS_IP"
echo "   }"
echo ""
echo "   Then restart CoreDNS:"
echo "   kubectl rollout restart deployment/coredns -n kube-system"
echo ""
echo "3. Tag your GPU machine with tag:gpu-inference:"
echo "   On GPU machine:"
echo "   curl -fsSL https://tailscale.com/install.sh | sh"
echo "   sudo tailscale up --advertise-tags=tag:gpu-inference"
echo ""
echo "4. Test connectivity:"
echo "   kubectl run test --image=nicolaka/netshoot -it --rm -- ping gpu-machine.your-tailnet.ts.net"
