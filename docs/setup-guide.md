# Pedro Ops Cluster Setup Guide

Complete step-by-step guide for deploying the pedro-ops Kubernetes cluster with Foundry CLI.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Phase 1: Pre-Deployment Verification](#phase-1-pre-deployment-verification)
3. [Phase 2: Foundry CLI Installation](#phase-2-foundry-cli-installation)
4. [Phase 3: Deploy Foundry Stack](#phase-3-deploy-foundry-stack)
5. [Phase 4: Tailscale Integration](#phase-4-tailscale-integration)
6. [Phase 5: Verification](#phase-5-verification)
7. [Post-Deployment](#post-deployment)
8. [Troubleshooting](#troubleshooting)

## Prerequisites

### Hardware Requirements

- **3 Linux servers** (Debian 11/12 or Ubuntu 22.04/24.04):
  - Control Plane: 100.81.89.62 (4+ CPU cores, 8GB+ RAM)
  - Worker 1: 100.70.90.12 (4+ CPU cores, 8GB+ RAM, **2TB storage drive**)
  - Worker 2: 100.125.196.1 (4+ CPU cores, 8GB+ RAM)
- **Network**: All nodes on same network, static IP addresses

### Software Requirements

On your **local machine**:
- Go 1.21 or higher
- kubectl 1.28+
- helm 3.13+
- SSH client with key-based authentication configured
- Git

On **all cluster nodes**:
- Fresh Debian 11/12 or Ubuntu 22.04/24.04 installation
- SSH server running
- Root access via SSH keys (no password authentication)

### Accounts and Credentials

- **Tailscale account** (free tier works)
  - Create at: https://login.tailscale.com/start
- **GitHub account** (for CI/CD, optional)

## Phase 1: Pre-Deployment Verification

**Estimated time: 30 minutes**

### Step 1.1: Verify SSH Access

Test SSH connectivity to all nodes:

```bash
# Clone the repository
git clone https://github.com/Soypete/pedro-ops.git
cd pedro-ops

# Run verification script
./scripts/phase1-verify-hosts.sh
```

**Expected output:**
```
=== Phase 1: Pre-Deployment Verification ===

[1/5] Verifying SSH Access...
✓ SSH access confirmed: 100.81.89.62
✓ SSH access confirmed: 100.70.90.12
✓ SSH access confirmed: 100.125.196.1
```

**If SSH fails:**
- Ensure SSH keys are in `~/.ssh/authorized_keys` on each node
- Test manually: `ssh root@100.81.89.62`
- Check firewall rules: `sudo ufw status`

### Step 1.2: Identify 2TB Drive

On Worker-1, identify the 2TB storage device:

```bash
ssh root@100.70.90.12 'lsblk'
```

Look for the 2TB drive (might be `/dev/sdb`, `/dev/nvme1n1`, etc.).

**Example output:**
```
NAME        SIZE TYPE MOUNTPOINT
sda         100G disk
├─sda1       99G part /
└─sda2        1G part [SWAP]
sdb           2T disk          <-- This is your 2TB drive
```

### Step 1.3: Format and Mount 2TB Drive

**⚠️ WARNING: This will ERASE all data on the specified device!**

```bash
./scripts/phase1-setup-storage.sh
```

When prompted:
1. Enter the device name (e.g., `/dev/sdb`)
2. Type `yes` to confirm

**Expected output:**
```
Formatting /dev/sdb with ext4 filesystem...
Creating mount point /data/persistent-storage...
Mounting /dev/sdb to /data/persistent-storage...
✓ Storage setup complete!
```

Verify the mount:

```bash
ssh root@100.70.90.12 'df -h /data/persistent-storage'
```

Should show ~2TB available.

### Step 1.4: Install Prerequisites

Install required packages on all nodes:

```bash
./scripts/phase1-install-prerequisites.sh
```

**Expected output:**
```
=== Installing prerequisites on 100.81.89.62 ===
  ✓ Prerequisites installed on 100.81.89.62

=== Installing prerequisites on 100.70.90.12 ===
  ✓ Prerequisites installed on 100.70.90.12

=== Installing prerequisites on 100.125.196.1 ===
  ✓ Prerequisites installed on 100.125.196.1
```

## Phase 2: Foundry CLI Installation

**Estimated time: 20 minutes**

### Step 2.1: Install Foundry CLI

```bash
./scripts/phase2-install-foundry.sh
```

This script will:
1. Clone the Foundry repository
2. Build the Foundry CLI
3. Install it to `/usr/local/bin/`
4. Initialize Foundry configuration
5. Copy `foundry/stack.yaml` to `~/.foundry/`

**Expected output:**
```
Foundry installed successfully:
foundry version v1.x.x
✓ Foundry CLI installed successfully!
```

Verify installation:

```bash
foundry --version
```

### Step 2.2: Add Hosts to Foundry

Add each node to Foundry's host inventory:

```bash
# Add control plane
foundry host add
```

When prompted, enter:
- **Hostname:** `control-plane`
- **IP Address:** `100.81.89.62`
- **User:** `root`
- **SSH Key:** (press Enter for default `~/.ssh/id_rsa`)

Repeat for worker nodes:

```bash
# Add worker-1
foundry host add
# Hostname: worker-1
# IP: 100.70.90.12
# User: root

# Add worker-2
foundry host add
# Hostname: worker-2
# IP: 100.125.196.1
# User: root
```

Verify hosts:

```bash
foundry host list
```

**Expected output:**
```
HOSTNAME        IP              USER  STATUS
control-plane   100.81.89.62    root  added
worker-1        100.70.90.12    root  added
worker-2        100.125.196.1   root  added
```

### Step 2.3: Configure Hosts

Prepare each host for Foundry deployment:

```bash
foundry host configure control-plane
foundry host configure worker-1
foundry host configure worker-2
```

This updates packages, syncs time, and installs dependencies.

### Step 2.4: Validate Configuration

```bash
foundry config validate
foundry validate
```

**Expected output:**
```
✓ Configuration is valid
✓ All pre-flight checks passed
```

## Phase 3: Deploy Foundry Stack

**Estimated time: 30-40 minutes**

### Step 3.1: Deploy the Stack

You can deploy manually or use the automated script:

**Option A: Automated Script (Recommended)**

```bash
./scripts/phase3-deploy-foundry.sh
```

This script will:
1. Create storage directories on Worker-1
2. Validate Foundry configuration
3. Install the complete stack
4. Wait for deployment to complete
5. Configure kubectl access

**Option B: Manual Deployment**

```bash
# Create storage directories
ssh root@100.70.90.12 'mkdir -p /data/persistent-storage/{openbao,longhorn,prometheus,loki,grafana}'
ssh root@100.70.90.12 'chmod -R 755 /data/persistent-storage'

# Install stack
foundry stack install

# Monitor progress
foundry stack status
```

**Expected output:**
```
[1/5] Creating storage directories on Worker-1...
✓ Storage directories created

[2/5] Validating Foundry configuration...
✓ Configuration validated

[3/5] Installing Foundry stack...
This will take 15-30 minutes...

[4/5] Waiting for stack to be ready...
✓ Stack is ready!

[5/5] Configuring kubectl access...
NAME            STATUS   ROLES                  AGE   VERSION
control-plane   Ready    control-plane,master   5m    v1.28.5+k3s1
worker-1        Ready    <none>                 4m    v1.28.5+k3s1
worker-2        Ready    <none>                 4m    v1.28.5+k3s1
```

### Step 3.2: Configure kubectl

```bash
# Export kubeconfig
export KUBECONFIG=~/.kube/pedro-ops-config

# Add to your shell profile for persistence
echo 'export KUBECONFIG=~/.kube/pedro-ops-config' >> ~/.bashrc
# or for zsh:
echo 'export KUBECONFIG=~/.kube/pedro-ops-config' >> ~/.zshrc
```

### Step 3.3: Verify Cluster

```bash
# Check nodes
kubectl get nodes -o wide

# Check all pods
kubectl get pods -A

# Check Foundry components
kubectl get pods -n openbao-system
kubectl get pods -n zot-system
kubectl get pods -n longhorn-system
kubectl get pods -n monitoring
```

All pods should be in `Running` or `Completed` state.

## Phase 4: Tailscale Integration

**Estimated time: 30 minutes**

### Step 4.1: Create OAuth Credentials

1. Go to [Tailscale OAuth settings](https://login.tailscale.com/admin/settings/oauth)
2. Click "**Generate OAuth Client**"
3. Copy the **Client ID** and **Client Secret**

### Step 4.2: Configure ACL Policy

1. Go to [Tailscale ACL settings](https://login.tailscale.com/admin/acls)
2. Copy the contents of `k8s/tailscale/acl-policy.json`
3. Paste into the ACL editor
4. Click "**Save**"

### Step 4.3: Enable MagicDNS

1. Go to [Tailscale DNS settings](https://login.tailscale.com/admin/dns)
2. Toggle "**Enable MagicDNS**"
3. Toggle "**Enable HTTPS**"

### Step 4.4: Install Tailscale Operator

```bash
# Set OAuth credentials as environment variables
export TS_CLIENT_ID="your_client_id_here"
export TS_CLIENT_SECRET="your_client_secret_here"

# Run installation script
./scripts/phase4-install-tailscale.sh
```

**Expected output:**
```
[1/6] Adding Tailscale Helm repository...
✓ Helm repository added

[2/6] Creating Tailscale namespace...
✓ Namespace created

[3/6] Installing Tailscale operator...
✓ Operator installed

[4/6] Waiting for operator to be ready...
✓ Operator is ready

[5/6] Deploying Tailscale connector...
✓ Connector deployed

[6/6] Deploying DNS configuration...
✓ DNS configuration deployed
```

### Step 4.5: Approve Routes

1. Go to [Tailscale Machines](https://login.tailscale.com/admin/machines)
2. Find the machine named "**pedro-ops-cluster**" or similar
3. Click on it
4. Click "**Approve**" for advertised routes

### Step 4.6: Configure CoreDNS

Get the Tailscale DNS service IP:

```bash
kubectl get svc -n tailscale tailscale-nameserver
```

Note the `CLUSTER-IP` (e.g., `10.43.123.45`).

Edit CoreDNS configuration:

```bash
kubectl edit configmap coredns -n kube-system
```

Add this block to the `Corefile` (replace `<TS_DNS_IP>` with actual IP):

```
ts.net:53 {
  errors
  cache 30
  forward . <TS_DNS_IP>
}
```

Save and exit. Restart CoreDNS:

```bash
kubectl rollout restart deployment/coredns -n kube-system
```

### Step 4.7: Configure GPU Machine

On your external GPU inference machine:

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Authenticate with tag
sudo tailscale up --advertise-tags=tag:gpu-inference

# Verify
tailscale status
```

### Step 4.8: Test Connectivity

From your cluster:

```bash
kubectl run test --image=nicolaka/netshoot -it --rm --restart=Never -- /bin/bash

# Inside the pod:
ping gpu-machine.your-tailnet.ts.net
nslookup gpu-machine.your-tailnet.ts.net
exit
```

Replace `gpu-machine.your-tailnet.ts.net` with your actual GPU machine's Tailscale DNS name.

## Phase 5: Verification

### Step 5.1: Validate Storage

```bash
./scripts/validate-storage.sh
```

**Expected output:**
```
[1/6] Checking 2TB drive mount on Worker-1...
✓ 2TB drive is mounted

[2/6] Checking storage directories...
  ✓ /data/persistent-storage/openbao exists
  ✓ /data/persistent-storage/longhorn exists
  ✓ /data/persistent-storage/prometheus exists
  ✓ /data/persistent-storage/loki exists
  ✓ /data/persistent-storage/grafana exists
```

### Step 5.2: Access Grafana

Get the Grafana admin password:

```bash
kubectl get secret -n monitoring grafana-admin-credentials \
  -o jsonpath='{.data.password}' | base64 -d
echo
```

Port-forward to Grafana:

```bash
kubectl port-forward -n monitoring svc/grafana 3000:3000
```

Open http://localhost:3000 in your browser:
- **Username:** `admin`
- **Password:** (from above command)

### Step 5.3: Access Prometheus

```bash
kubectl port-forward -n monitoring svc/prometheus-k8s 9090:9090
```

Open http://localhost:9090

### Step 5.4: Check All Components

```bash
# OpenBAO
kubectl get pods -n openbao-system

# PowerDNS
kubectl get pods -n powerdns-system

# Zot Registry
kubectl get pods -n zot-system

# Longhorn
kubectl get pods -n longhorn-system

# Monitoring
kubectl get pods -n monitoring

# Tailscale
kubectl get pods -n tailscale
```

## Post-Deployment

### Apply Kubernetes Manifests

```bash
# Apply base manifests
kubectl apply -k k8s/base

# Apply production overlays
kubectl apply -k k8s/overlays/production

# Verify
kubectl get all -n pedro-ops
```

### Set Up Backups

Configure Velero for automated backups (if using):

```bash
# Velero is included in Foundry stack
kubectl get pods -n velero

# Create a backup
velero backup create manual-backup-$(date +%Y%m%d)
```

### Configure Monitoring

1. Import Grafana dashboards
2. Set up Prometheus alerting rules
3. Configure notification channels

See [docs/monitoring.md](monitoring.md) for details.

## Troubleshooting

### Foundry Stack Installation Fails

```bash
# Check logs
foundry logs

# Check specific component
foundry component status k3s
foundry component logs k3s

# Uninstall and retry
foundry stack uninstall
# Fix issues, then:
foundry stack install
```

### Pods Not Starting

```bash
# Check pod status
kubectl get pods -A

# Describe problem pod
kubectl describe pod -n <namespace> <pod-name>

# Check logs
kubectl logs -n <namespace> <pod-name>

# Check events
kubectl get events -A --sort-by='.lastTimestamp'
```

### Storage Issues

```bash
# Check if drive is mounted
ssh root@100.70.90.12 'mount | grep /data/persistent-storage'

# Check disk space
ssh root@100.70.90.12 'df -h /data/persistent-storage'

# Check PV/PVC status
kubectl get pv
kubectl get pvc -A
```

### Tailscale Connectivity Issues

```bash
# Check operator logs
kubectl logs -n tailscale -l app=tailscale-operator

# Check connector status
kubectl describe connector -n tailscale gpu-inference-connector

# Verify routes in Tailscale admin
# Go to: https://login.tailscale.com/admin/machines
```

### DNS Resolution Issues

```bash
# Check CoreDNS
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Test DNS resolution
kubectl run test --image=nicolaka/netshoot -it --rm -- nslookup kubernetes.default.svc.cluster.local

# Check Tailscale DNS
kubectl run test --image=nicolaka/netshoot -it --rm -- nslookup gpu-machine.your-tailnet.ts.net
```

## Next Steps

1. **Deploy Applications**: See [README.md](../README.md#adding-new-applications)
2. **Configure Monitoring**: See [docs/monitoring.md](monitoring.md)
3. **Set Up CI/CD**: Configure GitHub Actions workflows
4. **Security Hardening**: Review [docs/security.md](security.md)
5. **Backup Strategy**: Configure automated backups

## Rollback Plan

If you need to start over:

```bash
# Uninstall Foundry stack
foundry stack uninstall

# Clean up nodes
for host in 100.81.89.62 100.70.90.12 100.125.196.1; do
  ssh root@$host '/usr/local/bin/k3s-uninstall.sh || true'
done

# Unmount storage (if needed)
ssh root@100.70.90.12 'umount /data/persistent-storage'

# Start from Phase 1
```

## Support

- Check [troubleshooting.md](troubleshooting.md)
- Review Foundry logs: `foundry logs`
- Consult Kubernetes events: `kubectl get events -A`
- Open an issue in the repository

---

**Time to completion:** Approximately 2.5-3 hours for full deployment
