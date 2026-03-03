#!/bin/bash
set -euo pipefail

# Phase 1: Pre-Deployment Verification Script
# Verifies host requirements for Foundry cluster deployment

echo "=== Phase 1: Pre-Deployment Verification ==="
echo ""

# Node IP addresses
CONTROL_PLANE="100.81.89.62"
WORKER_1="100.70.90.12"
WORKER_2="100.125.196.1"
VIP="100.81.89.100"

NODES=("$CONTROL_PLANE" "$WORKER_1" "$WORKER_2")

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if we can SSH to a host
check_ssh() {
    local host=$1
    if ssh -o ConnectTimeout=5 -o BatchMode=yes root@"$host" 'echo' &>/dev/null; then
        echo -e "${GREEN}✓${NC} SSH access confirmed: $host"
        return 0
    else
        echo -e "${RED}✗${NC} SSH access failed: $host"
        return 1
    fi
}

# Step 1: Verify SSH Access
echo "[1/5] Verifying SSH Access..."
echo "Testing SSH connectivity to all nodes..."
ssh_failed=0
for host in "${NODES[@]}"; do
    if ! check_ssh "$host"; then
        ssh_failed=1
    fi
done

if [ $ssh_failed -eq 1 ]; then
    echo -e "${RED}SSH access verification failed. Please configure SSH keys.${NC}"
    exit 1
fi
echo ""

# Step 2: Verify Host Requirements
echo "[2/5] Verifying Host Requirements..."
for host in "${NODES[@]}"; do
    echo "=== Host: $host ==="

    # OS version
    echo -n "  OS: "
    ssh root@"$host" 'cat /etc/os-release | grep -E "^PRETTY_NAME=" | cut -d= -f2' | tr -d '"'

    # Memory
    echo -n "  Memory: "
    ssh root@"$host" "free -h | grep Mem | awk '{print \$2}'"

    # CPU cores
    echo -n "  CPU cores: "
    ssh root@"$host" 'nproc'

    # Disk space
    echo "  Disk space:"
    ssh root@"$host" 'df -h | grep -E "^/dev" | head -3'

    echo ""
done
echo ""

# Step 3: Verify 2TB Drive on Worker-1
echo "[3/5] Verifying 2TB Drive on Worker-1..."
echo "=== Worker-1: $WORKER_1 ==="
echo "Block devices:"
ssh root@"$WORKER_1" 'lsblk'
echo ""
echo "Large disks (looking for 2TB):"
ssh root@"$WORKER_1" 'lsblk -b | awk '"'"'$4 > 1000000000000 {print $1, $4/1024/1024/1024 " GB"}'"'"
echo ""
echo -e "${YELLOW}NOTE: Identify the 2TB device name (e.g., /dev/sdb, /dev/nvme1n1) from above.${NC}"
echo -e "${YELLOW}You will need to format and mount it manually in the next script.${NC}"
echo ""

# Step 4: Verify Network Connectivity
echo "[4/5] Verifying Network Connectivity..."
echo "Testing inter-node connectivity..."

# Test from control plane
echo "  From control-plane to workers:"
ssh root@"$CONTROL_PLANE" "ping -c 2 -W 2 $WORKER_1 >/dev/null 2>&1 && echo '    ✓ control-plane → worker-1' || echo '    ✗ control-plane → worker-1 FAILED'"
ssh root@"$CONTROL_PLANE" "ping -c 2 -W 2 $WORKER_2 >/dev/null 2>&1 && echo '    ✓ control-plane → worker-2' || echo '    ✗ control-plane → worker-2 FAILED'"

# Test from worker-1
echo "  From worker-1 to other nodes:"
ssh root@"$WORKER_1" "ping -c 2 -W 2 $CONTROL_PLANE >/dev/null 2>&1 && echo '    ✓ worker-1 → control-plane' || echo '    ✗ worker-1 → control-plane FAILED'"
ssh root@"$WORKER_1" "ping -c 2 -W 2 $WORKER_2 >/dev/null 2>&1 && echo '    ✓ worker-1 → worker-2' || echo '    ✗ worker-1 → worker-2 FAILED'"

# Test VIP availability
echo "  Checking VIP availability ($VIP):"
if ping -c 2 -W 2 "$VIP" >/dev/null 2>&1; then
    echo -e "    ${RED}✗ VIP $VIP is already in use! Choose a different VIP.${NC}"
else
    echo -e "    ${GREEN}✓ VIP $VIP is available${NC}"
fi
echo ""

# Step 5: Check Prerequisites
echo "[5/5] Checking Prerequisites..."
for host in "${NODES[@]}"; do
    echo "=== Host: $host ==="

    # Check for required packages
    packages=("curl" "wget" "git" "socat" "conntrack" "ipset")
    for pkg in "${packages[@]}"; do
        if ssh root@"$host" "command -v $pkg" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} $pkg installed"
        else
            echo -e "  ${RED}✗${NC} $pkg NOT installed"
        fi
    done
    echo ""
done

echo "=== Pre-Deployment Verification Complete ==="
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Review the 2TB drive information above"
echo "2. Run scripts/phase1-setup-storage.sh to format and mount the 2TB drive"
echo "3. Run scripts/phase1-install-prerequisites.sh to install missing packages"
echo "4. Proceed to Phase 2: Foundry CLI installation"
