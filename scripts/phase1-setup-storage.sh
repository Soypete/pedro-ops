#!/bin/bash
set -euo pipefail

# Phase 1: Storage Setup Script
# Formats and mounts the 2TB drive on Worker-1

echo "=== Phase 1: Storage Setup on Worker-1 ==="
echo ""

WORKER_1="100.70.90.12"
MOUNT_POINT="/data/persistent-storage"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}WARNING: This script will format a disk. Make sure you have the correct device!${NC}"
echo ""

# Show available disks
echo "Available block devices on Worker-1:"
ssh root@"$WORKER_1" 'lsblk'
echo ""

# Prompt for device name
read -p "Enter the device name to format (e.g., /dev/sdb or /dev/nvme1n1): " DEVICE

# Confirm
echo ""
echo -e "${RED}You are about to format $DEVICE on Worker-1 ($WORKER_1)${NC}"
echo "This will DESTROY ALL DATA on $DEVICE!"
echo ""
read -p "Are you absolutely sure? Type 'yes' to continue: " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo "Formatting $DEVICE with ext4 filesystem..."
ssh root@"$WORKER_1" "mkfs.ext4 -F $DEVICE"

echo "Creating mount point $MOUNT_POINT..."
ssh root@"$WORKER_1" "mkdir -p $MOUNT_POINT"

echo "Mounting $DEVICE to $MOUNT_POINT..."
ssh root@"$WORKER_1" "mount $DEVICE $MOUNT_POINT"

echo "Adding to /etc/fstab for persistent mounting..."
ssh root@"$WORKER_1" "echo '$DEVICE $MOUNT_POINT ext4 defaults 0 2' >> /etc/fstab"

echo "Creating subdirectories for persistent storage..."
ssh root@"$WORKER_1" "mkdir -p $MOUNT_POINT/{openbao,longhorn,prometheus,loki,grafana}"
ssh root@"$WORKER_1" "chmod -R 755 $MOUNT_POINT"

echo ""
echo "Verifying mount:"
ssh root@"$WORKER_1" "df -h $MOUNT_POINT"

echo ""
echo -e "${GREEN}✓ Storage setup complete!${NC}"
echo ""
echo "Storage directories created:"
ssh root@"$WORKER_1" "ls -la $MOUNT_POINT"
