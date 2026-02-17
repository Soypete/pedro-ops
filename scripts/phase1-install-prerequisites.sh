#!/bin/bash
set -euo pipefail

# Phase 1: Install Prerequisites
# Installs required packages on all nodes

echo "=== Phase 1: Installing Prerequisites ==="
echo ""

CONTROL_PLANE="100.81.89.62"
WORKER_1="100.70.90.12"
WORKER_2="100.125.196.1"

NODES=("$CONTROL_PLANE" "$WORKER_1" "$WORKER_2")

# Colors
GREEN='\033[0;32m'
NC='\033[0m'

for host in "${NODES[@]}"; do
    echo "=== Installing prerequisites on $host ==="

    # Update package lists
    echo "  Updating package lists..."
    ssh root@"$host" 'apt-get update -qq'

    # Install required packages
    echo "  Installing packages..."
    ssh root@"$host" 'DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl \
        wget \
        git \
        socat \
        conntrack \
        ipset \
        nfs-common \
        open-iscsi \
        util-linux' >/dev/null 2>&1

    echo -e "  ${GREEN}✓ Prerequisites installed on $host${NC}"
    echo ""
done

echo "=== Prerequisite Installation Complete ==="
echo ""
echo "Next Steps:"
echo "1. Proceed to Phase 2: Install Foundry CLI"
echo "2. Run: scripts/phase2-install-foundry.sh"
