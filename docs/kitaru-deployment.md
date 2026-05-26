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

```bash
# Deploy with local values (no ingress, cluster-internal access)
helm install kitaru-server oci://public.ecr.aws/zenml/kitaru \
  --namespace kitaru \
  --create-namespace \
  -f helm/kitaru/values-local.yaml \
  --timeout 10m
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