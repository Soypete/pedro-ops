#!/bin/bash
set -euo pipefail

# Storage Validation Script
# Verifies 2TB drive configuration and usage

echo "=== Pedro Ops Storage Validation ==="
echo ""

WORKER_1="100.70.90.12"
MOUNT_POINT="/data/persistent-storage"

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

# Step 1: Check 2TB drive mount on Worker-1
echo "[1/6] Checking 2TB drive mount on Worker-1..."
if ssh root@"$WORKER_1" "df -h $MOUNT_POINT" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ 2TB drive is mounted${NC}"
    echo ""
    ssh root@"$WORKER_1" "df -h $MOUNT_POINT"
else
    echo -e "${RED}✗ 2TB drive is NOT mounted!${NC}"
    exit 1
fi
echo ""

# Step 2: Check storage directories
echo "[2/6] Checking storage directories..."
expected_dirs=("openbao" "longhorn" "prometheus" "loki" "grafana")

for dir in "${expected_dirs[@]}"; do
    if ssh root@"$WORKER_1" "test -d $MOUNT_POINT/$dir"; then
        echo -e "  ${GREEN}✓${NC} $MOUNT_POINT/$dir exists"
    else
        echo -e "  ${RED}✗${NC} $MOUNT_POINT/$dir missing"
    fi
done
echo ""

# Step 3: Check PersistentVolumes
echo "[3/6] Checking PersistentVolumes..."
if kubectl get pv >/dev/null 2>&1; then
    pv_count=$(kubectl get pv --no-headers 2>/dev/null | wc -l || echo "0")
    echo "Found $pv_count PersistentVolumes:"
    kubectl get pv -o wide
    echo ""

    # Check specific PVs
    for pv in openbao-pv prometheus-pv loki-pv grafana-pv; do
        if kubectl get pv "$pv" >/dev/null 2>&1; then
            status=$(kubectl get pv "$pv" -o jsonpath='{.status.phase}')
            echo -e "  ${GREEN}✓${NC} $pv ($status)"
        else
            echo -e "  ${YELLOW}!${NC} $pv not found (may be created by Foundry)"
        fi
    done
else
    echo -e "${YELLOW}No PersistentVolumes found${NC}"
fi
echo ""

# Step 4: Check PersistentVolumeClaims
echo "[4/6] Checking PersistentVolumeClaims..."
if kubectl get pvc -A >/dev/null 2>&1; then
    pvc_count=$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l || echo "0")
    echo "Found $pvc_count PersistentVolumeClaims:"
    kubectl get pvc -A -o wide
else
    echo -e "${YELLOW}No PersistentVolumeClaims found${NC}"
fi
echo ""

# Step 5: Check storage usage in pods
echo "[5/6] Checking storage usage in pods..."

# Check Prometheus storage
if kubectl get pod -n monitoring prometheus-k8s-0 >/dev/null 2>&1; then
    echo "Prometheus storage usage:"
    kubectl exec -n monitoring prometheus-k8s-0 -- df -h /prometheus || echo "  (Not accessible yet)"
else
    echo -e "  ${YELLOW}Prometheus pod not found${NC}"
fi
echo ""

# Check Grafana storage
if kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana >/dev/null 2>&1; then
    grafana_pod=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$grafana_pod" ]; then
        echo "Grafana storage usage:"
        kubectl exec -n monitoring "$grafana_pod" -- df -h /var/lib/grafana || echo "  (Not accessible yet)"
    fi
else
    echo -e "  ${YELLOW}Grafana pod not found${NC}"
fi
echo ""

# Step 6: Check disk usage on Worker-1
echo "[6/6] Checking detailed storage usage on Worker-1..."
echo "Directory sizes:"
ssh root@"$WORKER_1" "du -sh $MOUNT_POINT/* 2>/dev/null || echo 'No data yet'"
echo ""

echo "Total usage:"
ssh root@"$WORKER_1" "du -sh $MOUNT_POINT"
echo ""

# Summary
echo "=== Storage Validation Complete ==="
echo ""
echo -e "${GREEN}Next Steps:${NC}"
echo "1. If PVs are not created, apply them:"
echo "   kubectl apply -f k8s/monitoring/persistent-volumes.yaml"
echo ""
echo "2. Monitor storage usage over time:"
echo "   ssh root@$WORKER_1 'watch -n 60 du -sh /data/persistent-storage/*'"
echo ""
echo "3. Access Grafana to view metrics:"
echo "   kubectl port-forward -n monitoring svc/grafana 3000:3000"
