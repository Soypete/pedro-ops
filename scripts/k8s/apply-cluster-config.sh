#!/usr/bin/env bash
# apply-cluster-config.sh
# Applies cluster-level configuration for the pedro ops k3s cluster.
# Run this after setting up a new node or if CoreDNS/registry config is lost.
#
# Cluster nodes (Tailscale IPs):
#   blue1  (control plane + ZOT registry): 100.81.89.62  (LAN: 192.168.1.128)
#   blue2  (worker):                       100.125.196.1 (LAN: 192.168.1.11)
#   refurb (worker):                       100.70.90.12  (LAN: 192.168.1.253)
#
# Note: blue1 also has 100.118.20.111 (pedro-ops-api Tailscale device) on enp1s0.
# The k3s node-ip must be set to 192.168.1.128 to prevent flannel from binding to
# 100.118.20.111 as the VXLAN VTEP, which breaks cross-node pod networking.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Applying CoreDNS ConfigMap..."
kubectl apply -f "$SCRIPT_DIR/coredns-configmap.yaml"
kubectl rollout restart deployment coredns -n kube-system
kubectl rollout status deployment coredns -n kube-system --timeout=60s
echo "    CoreDNS updated successfully"

echo ""
echo "==> Applying k3s node-ip and registry config to all nodes..."
echo "    (requires SSH access as root to blue1, blue2, refurb)"

# blue1 (control plane)
echo "    -> blue1 (100.81.89.62)"
ssh root@100.81.89.62 "mkdir -p /etc/rancher/k3s && cat > /etc/rancher/k3s/config.yaml <<'EOF'
node-ip: 192.168.1.128
EOF"
scp "$SCRIPT_DIR/registries.yaml" "root@100.81.89.62:/etc/rancher/k3s/registries.yaml"
ssh root@100.81.89.62 "systemctl restart k3s"
echo "    <- blue1 done (cluster will be unavailable ~30s)"
sleep 35

# blue2 (worker)
echo "    -> blue2 (100.125.196.1)"
ssh root@100.125.196.1 "mkdir -p /etc/rancher/k3s && cat > /etc/rancher/k3s/config.yaml <<'EOF'
node-ip: 192.168.1.11
EOF"
scp "$SCRIPT_DIR/registries.yaml" "root@100.125.196.1:/etc/rancher/k3s/registries.yaml"
ssh root@100.125.196.1 "systemctl restart k3s-agent"
echo "    <- blue2 done"

# refurb (worker)
echo "    -> refurb (100.70.90.12)"
ssh root@100.70.90.12 "mkdir -p /etc/rancher/k3s && cat > /etc/rancher/k3s/config.yaml <<'EOF'
node-ip: 192.168.1.253
EOF"
scp "$SCRIPT_DIR/registries.yaml" "root@100.70.90.12:/etc/rancher/k3s/registries.yaml"
ssh root@100.70.90.12 "systemctl restart k3s-agent"
echo "    <- refurb done"

echo ""
sleep 15
echo "==> Verifying DNS resolution from cluster..."
kubectl run -it --rm dns-test --image=busybox --restart=Never -- nslookup controlplane.tailscale.com 2>/dev/null || true

echo ""
echo "==> Done. Cluster config applied."
echo "    ZOT registry: http://100.81.89.62:5000"
echo "    CoreDNS forwarding to: 8.8.8.8 1.1.1.1"
echo "    Flannel VTEP on all nodes uses LAN IPs (192.168.1.x)"
