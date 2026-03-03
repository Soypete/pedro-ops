# Tailscale Integration Setup Guide

## Prerequisites

- Foundry CLI installed
- Tailscale account with admin access
- K3s cluster installed (control plane running)

## Step 1: Create Tailscale OAuth Client

1. Go to https://login.tailscale.com/admin/settings/oauth
2. Click "+ Credential"
3. Select "OAuth client"
4. Set scopes to **"all"** (or minimum: **Devices: Write**)
5. Add description: `k8s-operator` or `foundry-pedro-ops`
6. Click "Generate client"
7. **Copy both Client ID and Client Secret** (secret is shown only once!)

## Step 2: Store OAuth Credentials

Create or update `~/.foundryvars` file:

```bash
# Tailscale OAuth Credentials
foundry-core/tailscale:client_id=<YOUR_CLIENT_ID>
foundry-core/tailscale:client_secret=<YOUR_CLIENT_SECRET>
```

**Security Note**: This file contains sensitive credentials. Ensure proper permissions:
```bash
chmod 600 ~/.foundryvars
```

## Step 3: Configure Tailscale ACL

1. Go to https://login.tailscale.com/admin/acls
2. Add required tags to `tagOwners` section:

```json
{
  "tagOwners": {
    "tag:k8s-operator": ["group:personal"],
    "tag:k8s-pedro-ops": ["group:personal"],
    "tag:production": ["group:personal"]
  }
}
```

**Important**: Tags must match those in your `stack.yaml` configuration.

3. Click "Save" to apply ACL changes

## Step 4: Update Stack Configuration

Edit `foundry/stack.yaml`:

```yaml
cluster:
  name: pedro-ops-cluster
  vip: 100.81.89.100
  allow_cgnat_vip: true
  use_tailscale: true

components:
  k3s:
    tls_san:
      - 100.81.89.62      # Control plane IP
      - 100.81.89.100     # VIP (required for multi-node)
      - soypetetech.local

  tailscale:
    oauth_client_id: ${secret:foundry-core/tailscale:client_id}
    oauth_client_secret: ${secret:foundry-core/tailscale:client_secret}
    tags:
      - tag:k8s-pedro-ops
      - tag:production
```

## Step 5: Install Tailscale Operator

```bash
foundry component install tailscale --config foundry/stack.yaml
```

## Step 6: Verify Installation

```bash
kubectl --kubeconfig ~/.foundry/kubeconfig get pods -n tailscale
kubectl --kubeconfig ~/.foundry/kubeconfig get connector -n tailscale
```

## Troubleshooting

See full guide at: https://github.com/catalystcommunity/foundry/issues/17

## Next Steps

1. Join worker nodes to cluster
2. Configure Tailscale Magic DNS
3. Test VIP connectivity from Tailscale devices
