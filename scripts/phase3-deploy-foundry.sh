#!/bin/bash
set -euo pipefail

# Phase 3: Deploy Foundry Stack

echo "=== Phase 3: Deploying Foundry Stack ==="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Node configuration
CONTROL_PLANE="100.81.89.62"
WORKER_1="100.70.90.12"
WORKER_2="100.125.196.1"

# Verify Foundry is installed
if ! command -v foundry &> /dev/null; then
    echo -e "${RED}Foundry CLI is not installed!${NC}"
    echo "Run: ./scripts/phase2-install-foundry.sh"
    exit 1
fi

# Create storage directories on Worker-1
echo "[1/5] Creating storage directories on Worker-1..."
ssh root@"$WORKER_1" 'mkdir -p /data/persistent-storage/{openbao,longhorn,prometheus,loki,grafana}'
ssh root@"$WORKER_1" 'chmod -R 755 /data/persistent-storage'
echo -e "${GREEN}✓ Storage directories created${NC}"
echo ""

# Validate Foundry configuration
echo "[2/5] Validating Foundry configuration..."
if ! foundry config validate; then
    echo -e "${RED}Foundry configuration validation failed!${NC}"
    exit 1
fi

if ! foundry validate; then
    echo -e "${RED}Pre-flight checks failed!${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Configuration validated${NC}"
echo ""

# Install Foundry stack
echo "[3/5] Installing Foundry stack..."
echo -e "${YELLOW}This will take 15-30 minutes...${NC}"
foundry stack install

echo -e "${GREEN}✓ Stack installation initiated${NC}"
echo ""

# Wait for installation to complete
echo "[4/5] Waiting for stack to be ready..."
echo "Checking stack status..."
sleep 30

# Monitor installation progress
while true; do
    if foundry stack status | grep -q "Status: Ready"; then
        echo -e "${GREEN}✓ Stack is ready!${NC}"
        break
    fi
    echo "Stack not ready yet, checking again in 30 seconds..."
    sleep 30
done
echo ""

# Get kubeconfig
echo "[5/5] Configuring kubectl access..."
foundry kubeconfig > ~/.kube/pedro-ops-config
export KUBECONFIG=~/.kube/pedro-ops-config

echo "Verifying cluster access..."
kubectl get nodes -o wide

echo ""
echo "Checking pod status across all namespaces..."
kubectl get pods -A

echo ""
echo -e "${GREEN}=== Foundry Stack Deployment Complete ===${NC}"
echo ""
echo "Cluster Information:"
echo "  Kubeconfig: ~/.kube/pedro-ops-config"
echo "  API Endpoint: https://100.81.89.100:6443"
echo "  Domain: soypetetech.local"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Verify all components:"
echo "   export KUBECONFIG=~/.kube/pedro-ops-config"
echo "   kubectl get pods -A"
echo ""
echo "2. Get Grafana password:"
echo "   kubectl get secret -n monitoring grafana-admin-credentials -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "3. Access services (port-forward):"
echo "   kubectl port-forward -n monitoring svc/grafana 3000:3000"
echo "   kubectl port-forward -n monitoring svc/prometheus-k8s 9090:9090"
echo ""
echo "4. Proceed to Phase 4: Tailscale Integration"
echo "   ./scripts/phase4-install-tailscale.sh"
