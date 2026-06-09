# Kitaru Deployment Guide

**Date:** May 26, 2026
**Cluster:** pedro-ops (3-node K3s via Foundry)
**Status:** Ready for Deployment

## Overview

[Kitaru](https://kitaru.ai) is a durable execution layer for AI agents. It provides primitives that make agent workflows persistent, replayable, and observable. This guide covers deployment to the pedro-ops Kubernetes cluster.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    pedro-ops Cluster                        │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                   kitaru Namespace                   │   │
│  │  ┌─────────────────────────────────────────────┐   │   │
│  │  │         kitaru-server (Deployment)          │   │   │
│  │  │   - REST API (port 80)                      │   │   │
│  │  │   - Dashboard UI                            │   │   │
│  │  │   - SQLite with persistence                 │   │   │
│  │  └─────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────┘   │
│                            │                                 │
│  ┌─────────────────────────┴───────────────────────────┐   │
│  │         Longhorn Storage (50Gi PVC)                  │   │
│  │         Dynamically provisioned                      │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                   Internal Access                           │
│  - ClusterIP: kitaru.kitaru.svc.cluster.local              │
│  - Port-forward: kubectl port-forward -n kitaru svc/kitaru-server-kitaru 8080:80
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

1. **Storage**: Longhorn (dynamic PVC provisioning, 50Gi)
2. **Namespace**: Already created via `k8s/base/kitaru-namespace.yaml`
3. **Helm Chart**: Uses official Kitaru chart from Amazon ECR

## Deployment Steps

### 1. Apply Base Resources

```bash
# Apply namespace and base resources
kubectl apply -k k8s/base/

# Verify namespace
kubectl get namespace kitaru
```

### 2. Deploy Kitaru with Helm

**Note:** We deploy from the control plane because the chart has a dependency on `zenml` from ECR public, which requires AWS authentication. The control plane has the necessary credentials.

```bash
# SSH to control plane
ssh root@100.81.89.62

# Clone the kitaru-go repo (if not already present)
git clone https://github.com/Soypete/kitaru-go /tmp/kitaru-go

# Build Helm dependencies (fetches zenml from ECR public)
cd /tmp/kitaru-go/helm && helm dependency build

# Deploy with correct image tag (latest, not 0.94.3 which doesn't exist)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
helm install kitaru-server /tmp/kitaru-go/helm \
  --namespace kitaru \
  --set kitaru.server.image.repository=zenmldocker/kitaru \
  --set kitaru.server.image.tag=latest \
  --set kitaru.server.ingress.enabled=false \
  --set kitaru.server.service.type=ClusterIP \
  --set kitaru.server.database.persistence.enabled=true \
  --set kitaru.server.database.persistence.size=50Gi \
  --set kitaru.server.database.persistence.storageClassName=longhorn \
  --set kitaru.server.auth.jwtSecretKey=<your-secret-key> \
  --set kitaru.server.secretsStore.enabled=true \
  --set kitaru.server.secretsStore.type=sql \
  --set kitaru.server.secretsStore.sql.encryptionKey=<your-encryption-key> \
  --timeout 15m
```

### 3. Verify Deployment

```bash
# Check pod status
kubectl get pods -n kitaru

# Check Helm release
helm list -n kitaru

# Watch for pod to be ready
kubectl rollout status deployment/kitaru-server-kitaru -n kitaru
```

### 4. Access the Dashboard

#### Option A: Port Forward (Recommended for Local Access)

```bash
# Port-forward to access the dashboard
kubectl port-forward -n kitaru svc/kitaru-server-kitaru 8080:80

# Then access in browser: http://localhost:8080
```

#### Option B: NodePort (Alternative)

```bash
# If you need direct node access, modify service type
kubectl patch svc kitaru-server-kitaru -n kitaru -p '{"spec":{"type":"NodePort"}}'

# Access via node IP and assigned port
kubectl get svc -n kitaru
```

## Accessing the Dashboard

**Yes, there is a built-in web UI!**

Once deployed, access the Kitaru dashboard:

1. **Local port-forward** (recommended):
   ```bash
   kubectl port-forward -n kitaru svc/kitaru-server-kitaru 8080:80
   # Open http://localhost:8080 in browser
   ```

2. **Connect with CLI**:
   ```bash
   pip install kitaru
   kitaru login http://localhost:8080
   ```

## Authentication

After first deployment, the server requires a user account. Use the web UI to create one:

1. Port-forward: `kubectl port-forward -n kitaru svc/kitaru-server-kitaru 8080:80`
2. Open http://localhost:8080 in browser
3. Click "Create account" or sign up
4. Create user: e.g., username `admin`, password `admin`

**Alternative: Direct database update** (if UI fails):

```bash
# Generate bcrypt hash
kubectl exec -n kitaru kitaru-server-55cf77d46-22kpn -- python3 -c "
import bcrypt
print(bcrypt.hashpw('admin'.encode(), bcrypt.gensalt()).decode())
"

# Update password in DB (replace HASH with output above)
kubectl exec -n kitaru kitaru-server-55cf77d46-22kpn -- python3 -c "
import sqlite3
conn = sqlite3.connect('/zenml/.zenconfig/local_stores/default_zen_store/zenml.db')
cursor = conn.cursor()
cursor.execute('UPDATE user SET password = ? WHERE name = ?', ('HASH', 'admin'))
conn.commit()
"
```

**Test authentication:**
```bash
curl -X POST http://localhost:8080/api/v1/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=admin"
```

## DNS and Tailscale

### Do you need Tailscale DNS?

**No, not for internal cluster access.** Here's the breakdown:

| Access Type | Method | DNS Required? |
|-------------|--------|---------------|
| From cluster pods | ClusterIP (internal) | No |
| From cluster nodes | Node IP + NodePort | No |
| From laptop (via kubectl port-forward) | localhost | No |
| From laptop (direct connection) | Tailscale DNS | Yes |

### To expose externally via Tailscale

If you want to access Kitaru directly from your laptop without port-forwarding:

1. Create a Tailscale LoadBalancer service (already configured in cluster)
2. Access via: `http://kitaru.soypetetech.local` (if DNS configured)
3. Or access via Tailscale IP: `http://100.x.x.x` (assigned by Tailscale)

## OpenBAO Secrets

OpenBAO is running as a Docker container on the control plane:

- **Location**: `100.81.89.62` (control-plane)
- **Port**: 8200
- **Protocol**: HTTP (TLS disabled)
- **Token location**: `~/.foundry/openbao-keys/test/keys.json`

### Store Secrets

```bash
# Using root token from ~/.foundry/openbao-keys/test/keys.json
export TOKEN="s.8sy7M9skEVO47Gsn12BtBjgO"

# Store kitaru secrets
curl -s http://100.81.89.62:8200/v1/secret/data/kitaru \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-Vault-Token: $TOKEN" \
  -d '{"data": {"jwt_secret": "your-jwt-secret", "encryption_key": "your-encryption-key"}}'
```

### Read Secrets

```bash
curl -s http://100.81.89.62:8200/v1/secret/data/kitaru \
  -H "X-Vault-Token: $TOKEN" | jq .data.data
```

### OpenBAO Injector

The cluster has the OpenBAO injector running (but not fully configured). To use it:

1. Add annotations to pod:
   ```yaml
   annotations:
     "vault.hashicorp.com/agent-inject": "true"
     "vault.hashicorp.com/agent-inject-secret-kitaru": "secret/data/kitaru"
     "vault.hashicorp.com/role": "kitaru"
   ```

2. Create a Vault policy and role in OpenBAO

## Configuration Options

### Production Values (with Ingress)

For production with external ingress via Contour:

```bash
helm install kitaru-server oci://public.ecr.aws/zenml/kitaru \
  --namespace kitaru \
  -f helm/kitaru/values.yaml \
  --timeout 10m
```

### Database Options

Currently using local SQLite with persistent volume. For production with external MySQL:

1. Create MySQL database in Supabase or other provider
2. Update `helm/kitaru/values.yaml`:
   ```yaml
   kitaru:
     server:
       database:
         url: "mysql://user:password@host:3306/kitaru"
   ```

## Common Tasks

### Check Logs

```bash
kubectl logs -n kitaru deployment/kitaru-server-kitaru
```

### Upgrade Deployment

```bash
helm upgrade kitaru-server oci://public.ecr.aws/zenml/kitaru \
  -n kitaru \
  -f helm/kitaru/values-local.yaml
```

### Uninstall

```bash
helm uninstall kitaru-server -n kitaru

# Optional: Delete PVC to remove data
kubectl delete pvc -n kitaru -l app.kubernetes.io/instance=kitaru-server
```

## Troubleshooting

### Pod stuck in Pending

Check PV binding:
```bash
kubectl describe pvc -n kitaru
kubectl get pv
```

### Pod in CrashLoopBackOff

Check logs:
```bash
kubectl logs -n kitaru deployment/kitaru-server-kitaru --previous
```

### Cannot connect to dashboard

Verify service:
```bash
kubectl get svc -n kitaru
kubectl get endpoints -n kitaru
```

## Next Steps

1. Review and merge PR
2. Deploy to cluster
3. Connect with `kitaru login http://localhost:8080`
4. Follow [Kitaru Quick Start](https://kitaru.ai/docs) to create your first flow