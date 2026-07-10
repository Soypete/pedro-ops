# Pedro Ops Maintenance Guide

## Overview

This document covers operational maintenance tasks for the Pedro Ops Kubernetes cluster.

## Storage Overview

| Service | Storage Type | PVC | Size | Location |
|---------|-------------|-----|------|----------|
| PostgreSQL (OpenWebUI) | Longhorn | openwebui-db-1, openwebui-db-2 | 10Gi each | Worker-1 2TB drive |
| SeaweedFS | Longhorn | data-seaweedfs-volume-0 | 50Gi | Worker-1 2TB drive |
| Prometheus | Longhorn | prometheus-... | 200Gi | Worker-1 2TB drive |
| Grafana | Longhorn | grafana | 5Gi | Worker-1 2TB drive |
| Loki | Longhorn | storage-loki-0 | 10Gi | Worker-1 2TB drive |

## Backup & Restore

### PostgreSQL (OpenWebUI)

The OpenWebUI database runs on CloudNativePG with 2 replicas on Longhorn storage.

**Manual Backup (Longhorn Snapshots):**
```bash
./scripts/backup-openwebui-pg.sh
```

This creates VolumeSnapshots for both PostgreSQL PVCs.

**List Snapshots:**
```bash
kubectl get volumesnapshot -n openwebui
```

**Restore from Snapshot:**
```bash
# Create new PVC from snapshot
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openwebui-db-restore
  namespace: openwebui
spec:
  dataSource:
    name: <snapshot-name>
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  storageClassName: longhorn
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
EOF
```

### Longhorn Backups

Longhorn has built-in backup to NFS/S3. Configure in Longhorn UI.

```bash
# Access Longhorn UI
kubectl port-forward -n longhorn-system svc/longhorn-frontend 7000:80
```

## Upgrades

### OpenWebUI
```bash
helm repo update
helm upgrade openwebui open-webui/open-webui -n openwebui
```

### PostgreSQL (CloudNativePG)
Edit `k8s/openwebui/postgres.yaml` to change image version, then:
```bash
kubectl apply -f k8s/openwebui/postgres.yaml
```

### CloudNativePG Operator
```bash
helm upgrade cnpg-system cnpg/cloudnative-pg -n cnpg-system
```

## Monitoring

### Check Cluster Health
```bash
# Cluster status
kubectl get nodes

# Pod status
kubectl get pods -A

# PVC status
kubectl get pvc -A

# CloudNativePG cluster
kubectl get cluster -A
```

### View Logs
```bash
# OpenWebUI
kubectl logs -n openwebui -l app.kubernetes.io/name=open-webui

# PostgreSQL
kubectl logs -n openwebui -l cnpg.io/cluster=openwebui-db

# All OpenWebUI components
kubectl logs -n openwebui --all-containers=true
```

## Secrets Management

All secrets are stored in OpenBAO.

```bash
# Set Vault address
export VAULT_ADDR=http://100.81.89.62:8200
export VAULT_TOKEN=s.8sy7M9skEVO47Gsn12BtBjgO

# List secrets
vault kv list secret/pedro/

# Get secret
vault kv get secret/pedro/openwebui

# Update secret
vault kv put secret/pedro/openwebui KEY=value
```

## Common Tasks

### Restart OpenWebUI
```bash
kubectl rollout restart deployment -n openwebui
```

### Connect to PostgreSQL
```bash
# Get password
kubectl get secret openwebui-db-app -n openwebui -o jsonpath='{.data.password}' | base64 -d

# Port forward
kubectl port-forward -n openwebui svc/openwebui-db-rw 5432

# Connect
psql -h localhost -U postgres -d openwebui
```

### Scale PostgreSQL
Edit `k8s/openwebui/postgres.yaml` to change `instances`, then:
```bash
kubectl apply -f k8s/openwebui/postgres.yaml
```

### Check Longhorn Volume Health
```bash
kubectl get volumes.longhorn.io -A
```

## Tailscale

Tailscale provides external access to cluster services.

```bash
# Check tailscale-operator status
kubectl get tailscale -A

# View connected devices
tailscale status
```

## Resource Limits

| Component | CPU Limit | Memory Limit |
|-----------|-----------|--------------|
| openwebui-db | 500m | 512Mi |
| open-webui | - | - |
| Redis | - | - |

## OpenWebUI Management

### Architecture

OpenWebUI runs in the `openwebui` namespace with the following components:
- **openwebui-open-webui**: Main web UI (port 8080)
- **openwebui-open-webui-redis**: WebSocket message broker
- **openwebui-pipelines**: AI pipelines plugin
- **openwebui-tika**: Document text extraction

Database: CloudNativePG PostgreSQL cluster with pgvector in `openwebui` namespace.
Storage: Longhorn volumes on Worker-1 2TB drive.

### Deploy/Update OpenWebUI

```bash
# Update Helm values if needed
vim helm/openwebui/values.yaml

# Deploy/upgrade
helm upgrade openwebui open-webui/open-webui -n openwebui -f helm/openwebui/values.yaml

# Verify deployment
kubectl get pods -n openwebui
```

### Update Database (PostgreSQL)

Edit `k8s/openwebui/postgres.yaml` to change:
- Image version (`spec.image`)
- Instance count (`spec.instances`)
- Resources/storage

```bash
kubectl apply -f k8s/openwebui/postgres.yaml

# Verify cluster status
kubectl get cluster -n openwebui
```

### Update Redis

```bash
# Redis is deployed via Helm chart sub-chart
helm upgrade openwebui open-webui/open-webui -n openwebui -f helm/openwebui/values.yaml
```

### Connect to PostgreSQL

```bash
# Get password
kubectl get secret openwebui-db-app -n openwebui -o jsonpath='{.data.password}' | base64 -d

# Port forward to primary
kubectl port-forward -n openwebui svc/openwebui-db-rw 5432

# Connect (use password from above)
psql -h localhost -U postgres -d openwebui
```

### Debug OpenWebUI

```bash
# Check pod status
kubectl get pods -n openwebui

# View logs
kubectl logs -n openwebui deploy/openwebui-open-webui -c openwebui --tail=50

# Check environment variables
kubectl get deploy openwebui-open-webui -n openwebui -o jsonpath='{.spec.template.spec.containers[0].env}' | jq

# Check for errors in all containers
kubectl logs -n openwebui --all-containers=true --tail=100 | grep -i error
```

### Test Model Backend Connection

The GPU inference runs on `100.121.229.114:8000` (pedrogpt.tail6fbc5.ts.net via Tailscale).

```bash
# From your local machine (with Tailscale)
curl http://pedrogpt:8000/v1/models

# From a pod in cluster
kubectl run curl-test --image=curlimages/curl --restart=Never -n openwebui -- curl http://100.121.229.114:8000/v1/models

# Check OpenWebUI can reach the backend (look for connection errors in logs)
kubectl logs -n openwebui deploy/openwebui-open-webui | grep -i "connection\|error\|failed"
```

### Common Issues

**"Server Connection Error" in OpenWebUI UI:**
- Check that `OPENAI_API_BASE_URL` is set to IP address (not hostname): `http://100.121.229.114:8000/v1`
- Verify model backend is running: `curl http://100.121.229.114:8000/v1/models`
- Check pods can resolve DNS (may need to use IP instead of hostname)

**Chats not saving:**
- Verify PostgreSQL is running: `kubectl get cluster -n openwebui`
- Check database connection in logs
- Ensure VECTOR_DB=pgvector is set

**WebSocket issues:**
- Check Redis is running: `kubectl get pods -n openwebui | grep redis`
- Verify `websocket.manager: redis` in values.yaml

### Restart OpenWebUI

```bash
# Restart all deployments
kubectl rollout restart deployment -n openwebui

# Watch status
kubectl rollout status deployment -n openwebui
```

## Troubleshooting

See [troubleshooting.md](./troubleshooting.md) for common issues.