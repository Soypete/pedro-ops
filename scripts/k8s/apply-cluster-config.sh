#!/usr/bin/env bash
# apply-cluster-config.sh
# Applies cluster-level configuration for the pedro ops k3s cluster.
# Run this after setting up a new node or if CoreDNS/registry config is lost.
#
# Cluster nodes:
#   blue1 (control plane + ZOT registry): 100.81.89.62
#   blue2 (worker):                        100.70.90.12
#   refurb (worker):                       100.125.196.1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Applying CoreDNS ConfigMap..."
kubectl apply -f "$SCRIPT_DIR/coredns-configmap.yaml"
kubectl rollout restart deployment coredns -n kube-system
kubectl rollout status deployment coredns -n kube-system --timeout=60s
echo "    CoreDNS updated successfully"

echo ""
echo "==> Applying k3s registry config to all nodes..."
echo "    (requires SSH access to blue1, blue2, refurb)"

for NODE_IP in 100.81.89.62 100.70.90.12 100.125.196.1; do
    echo "    -> $NODE_IP"
    ssh "$NODE_IP" "sudo mkdir -p /etc/rancher/k3s/"
    scp "$SCRIPT_DIR/registries.yaml" "${NODE_IP}:/tmp/registries.yaml"
    ssh "$NODE_IP" "sudo cp /tmp/registries.yaml /etc/rancher/k3s/registries.yaml"

    if [ "$NODE_IP" = "100.81.89.62" ]; then
        ssh "$NODE_IP" "sudo systemctl restart k3s"
    else
        ssh "$NODE_IP" "sudo systemctl restart k3s-agent"
    fi
    echo "    <- $NODE_IP done"
done

echo ""
echo "==> Verifying DNS resolution from cluster..."
kubectl run -it --rm dns-test --image=busybox --restart=Never -- nslookup controlplane.tailscale.com 2>/dev/null || true

echo ""
echo "==> Done. Cluster config applied."
echo "    ZOT registry: http://100.81.89.62:5000"
echo "    CoreDNS forwarding to: 8.8.8.8 1.1.1.1"
