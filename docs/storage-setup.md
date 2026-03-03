# Storage Setup - Pedro Ops Cluster

This document describes the persistent storage configuration for the pedro-ops K3s cluster.

## Overview

The cluster uses a 2TB physical drive on **worker-1** (100.70.90.12) as the backend for Longhorn distributed storage. This provides persistent volumes for:
- OpenBAO secrets storage
- Prometheus metrics retention (15 days)
- Loki log retention (7 days)
- Grafana dashboards and configuration
- SeaweedFS object storage (500Gi)

## Hardware Configuration

- **Node**: worker-1 (100.70.90.12)
- **Physical Drive**: 2TB drive
- **Volume Group**: ubuntu-vg (LVM)
- **Logical Volume**: data-lv (1.5TB)
- **Mount Point**: /data/persistent-storage
- **Filesystem**: ext4

## LVM Setup

The storage was configured using LVM (Logical Volume Management) to provide flexibility for future expansion or modification.

### Create Logical Volume

```bash
# SSH to worker-1
ssh root@100.70.90.12

# Create 1.5TB logical volume from ubuntu-vg volume group
lvcreate -L 1.5T -n data-lv ubuntu-vg
```

**Output:**
```
Logical volume "data-lv" created.
```

### Format with ext4

```bash
# Format the logical volume with ext4 filesystem
mkfs.ext4 /dev/ubuntu-vg/data-lv
```

**Output:**
```
Creating filesystem with 402653184 4k blocks and 100663296 inodes
Filesystem UUID: acfd5f02-3381-4c29-87a0-84ccd9482c37
...
Writing superblocks and filesystem accounting information: done
```

### Mount the Filesystem

```bash
# Create mount point
mkdir -p /data/persistent-storage

# Mount the filesystem
mount /dev/ubuntu-vg/data-lv /data/persistent-storage
```

### Make Persistent Across Reboots

```bash
# Add entry to /etc/fstab
cat >> /etc/fstab <<EOF
/dev/ubuntu-vg/data-lv /data/persistent-storage ext4 defaults 0 2
EOF

# Verify fstab entry
tail -1 /etc/fstab
```

### Verify Mount

```bash
# Check filesystem is mounted
df -h /data/persistent-storage
```

**Output:**
```
Filesystem                       Size  Used Avail Use% Mounted on
/dev/mapper/ubuntu--vg-data--lv  1.5T   28K  1.5T   1% /data/persistent-storage
```

## Longhorn Configuration

Longhorn is configured to use this mount point as its storage backend with 2 replicas across worker nodes.

**Foundry stack.yaml configuration:**
```yaml
components:
  longhorn:
    default_storage_class: true
    enabled: true
    host_path: /data/persistent-storage/longhorn
    replicas: 2
```

## Storage Allocation

Current allocations from the 1.5TB volume:

- **Longhorn**: Dynamic allocation (default storage class)
  - OpenBAO: File-based storage backend
  - Prometheus: 15-day retention
  - Loki: 7-day retention
  - Grafana: Configuration and dashboards
- **SeaweedFS**: 500Gi S3-compatible object storage
- **Zot**: 100Gi container registry storage

## Verification Steps

After setup, verify the storage is working:

```bash
# Check mount point
df -h /data/persistent-storage

# Verify fstab entry
cat /etc/fstab | grep data-lv

# Check Longhorn is using the path
ls -la /data/persistent-storage/longhorn

# Verify from K8s cluster
kubectl get pv
kubectl get pvc -A
kubectl get storageclass
```

## Maintenance

### Extend Volume (if needed)

If more space is required:

```bash
# Extend logical volume (example: add 500GB)
lvextend -L +500G /dev/ubuntu-vg/data-lv

# Resize filesystem
resize2fs /dev/ubuntu-vg/data-lv

# Verify new size
df -h /data/persistent-storage
```

### Monitor Usage

```bash
# Check filesystem usage
df -h /data/persistent-storage

# Check LVM volume group free space
vgdisplay ubuntu-vg | grep Free

# Check Longhorn volume usage (from K8s)
kubectl get pv -o custom-columns=NAME:.metadata.name,CAPACITY:.spec.capacity.storage,STATUS:.status.phase
```

## Troubleshooting

### Mount Issues After Reboot

If the volume doesn't mount after reboot:

```bash
# Check systemd mount status
systemctl status data-persistent\\x2dstorage.mount

# Manually mount
mount /data/persistent-storage

# Check fstab syntax
mount -a
```

### LVM Volume Not Found

If the logical volume disappears:

```bash
# Scan for volume groups
vgscan

# Activate volume group
vgchange -ay ubuntu-vg

# List logical volumes
lvs
```

### Longhorn Storage Issues

If Longhorn has storage problems:

```bash
# Check Longhorn manager logs
kubectl logs -n longhorn-system -l app=longhorn-manager

# Verify host path exists on worker nodes
ssh root@100.70.90.12 "ls -la /data/persistent-storage/longhorn"

# Check Longhorn node status
kubectl get nodes.longhorn.io -n longhorn-system
```

## References

- [LVM Administration Guide](https://tldp.org/HOWTO/LVM-HOWTO/)
- [Longhorn Documentation](https://longhorn.io/docs/)
- [Foundry Stack Configuration](../foundry/stack.yaml)
- [Storage Backend Selection](../foundry/docs/storage-backends.md)
