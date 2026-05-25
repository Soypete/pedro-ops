# Foundry Configuration

This directory contains the Foundry CLI configuration for the pedro-ops Kubernetes cluster.

## Overview

The cluster is a K3s-based setup with the following components:

| Component | Status | Description |
|-----------|--------|-------------|
| **Longhorn** | ✅ Installed | Distributed block storage |
| **Prometheus** | ✅ Installed | Metrics collection (via kube-prometheus-stack CR) |
| **Loki** | ✅ Installed | Log aggregation |
| **Grafana** | ✅ Installed | Observability dashboards |
| **Contour** | ✅ Installed | Ingress controller (Envoy-based) |
| **Velero** | ✅ Installed | Backup/restore |
| **SeaweedFS** | ✅ Installed | S3-compatible object storage |
| **External-DNS** | ⚠️ Installed | DNS sync (not actively used) |
| **Tailscale Operator** | ✅ Installed | Tailscale Kubernetes integration |
| **OpenBAO Injector** | ✅ Installed | Secrets injection |

## Cluster Access

### Via Tailscale

The cluster API server is accessible via Tailscale IP:

```
kubeconfig: ~/.foundry/kubeconfig
Server: https://100.81.89.62:6443
```

### Prerequisites

1. Connect to Tailscale
2. Use the kubeconfig in `~/.foundry/kubeconfig`

### Quick Access

```bash
# List nodes
kubectl --kubeconfig ~/.foundry/kubeconfig get nodes

# List all pods
kubectl --kubeconfig ~/.foundry/kubeconfig get pods -A

# Check specific namespace
kubectl --kubeconfig ~/.foundry/kubeconfig get pods -n monitoring
```

## Current Stack Configuration

See `stack.yaml` for the current configuration. Key settings:

- **Cluster**: `test` (3 nodes: blue1, blue2, refurb)
- **Network**: 10.0.0.0/24 gateway at 10.0.0.1
- **VIP**: 10.0.0.11
- **Storage**: Longhorn (default StorageClass)

## Installed Components

### Helm Releases

```bash
kubectl --kubeconfig ~/.foundry/kubeconfig helm list -A
```

| Release | Namespace | Status |
|---------|-----------|--------|
| longhorn | longhorn-system | deployed |
| kube-prometheus-stack | monitoring | deployed |
| loki | monitoring | deployed |
| grafana | monitoring | deployed |
| contour | projectcontour | deployed |
| external-dns | external-dns | deployed |
| velero | velero | deployed |
| seaweedfs | seaweedfs | deployed |
| tailscale-operator | tailscale | deployed |
| openbao-injector | openbao | deployed |

### Node Information

```
NAME     STATUS   ROLES                AGE   VERSION
blue1    Ready    control-plane,etcd   89d   v1.34.3+k3s3
blue2    Ready    <none>               85d   v1.34.4+k3s1
refurb   Ready    <none>               85d   v1.34.4+k3s1
```

## Common Operations

### Check Component Status

```bash
# Via foundry (requires config)
foundry component status prometheus
foundry component status loki
foundry component status storage
```

### Access Services

```bash
# Port forward to Grafana
kubectl --kubeconfig ~/.foundry/kubeconfig port-forward -n monitoring svc/grafana 3000:3000

# Port forward to Longhorn UI
kubectl --kubeconfig ~/.foundry/kubeconfig port-forward -n longhorn-system svc/longhorn-frontend 8080:80

# Access Loki
kubectl --kubeconfig ~/.foundry/kubeconfig port-forward -n monitoring svc/loki-gateway 3100:80
```

### Get Credentials

```bash
# Grafana admin password
kubectl --kubeconfig ~/.foundry/kubeconfig get secret -n monitoring grafana-admin-credentials -o jsonpath='{.data.password}' | base64 -d

# OpenBAO (if needed)
# Check openbao namespace for secrets
kubectl --kubeconfig ~/.foundry/kubeconfig get secret -n openbao
```

## Tailscale Integration

The cluster uses Tailscale for:

1. **API Server Access**: Kubeconfig points to Tailscale IP (100.81.89.62)
2. **DNS**: Tailscale DNS handles internal resolution
3. **Service Exposure**: Some services exposed via Tailscale Funnel/Serve
4. **Operator**: tailscale-operator manages pod networking

### Tailscale DNS

Services are accessible via:
- `*.tail6fbc5.ts.net` (Tailscale funnel)
- Custom domains via Contour ingress

### Current Ingresses

```bash
kubectl --kubeconfig ~/.foundry/kubeconfig get ingress -A
```

| Namespace | Service | Type | Host |
|-----------|---------|------|------|
| monitoring | grafana | contour | grafana.soypetetech.local |
| monitoring | loki-gateway | contour | loki.soypetetech.local |
| longhorn-system | longhorn-ingress | contour | longhorn.soypetetech.local |
| seaweedfs | ingress-seaweedfs-filer | contour | seaweedfs.soypetetech.local |
| seaweedfs | ingress-seaweedfs-s3 | contour | s3.soypetetech.local |
| chatbot | pedro-twitch-auth | tailscale | chatbot-pedro-twitch-auth-ingress.tail6fbc5.ts.net |
| pedrocli | pedrocli-ingress | tailscale | pedrocli-pedrocli-ingress-ingress.tail6fbc5.ts.net |

## Storage

### Longhorn

Default StorageClass: `longhorn`

```bash
# Check volumes
kubectl --kubeconfig ~/.foundry/kubeconfig get volumes -n longhorn-system

# Check storage classes
kubectl --kubeconfig ~/.foundry/kubeconfig get storageclass
```

Available StorageClasses:
- `longhorn` (default) - Dynamic provisioning
- `longhorn-static` - Static provisioning
- `local-path` - K3s bundled local storage

### SeaweedFS

S3-compatible storage:

```bash
# Access SeaweedFS S3
# Endpoint: seaweedfs-seaweedfs-s3.seaweedfs.svc.cluster.local:8333
```

## Troubleshooting

### Check Pod Health

```bash
# All pods with issues
kubectl --kubeconfig ~/.foundry/kubeconfig get pods -A | grep -v Running

# Specific namespace
kubectl --kubeconfig ~/.foundry/kubeconfig get pods -n monitoring
kubectl --kubeconfig ~/.foundry/kubeconfig get pods -n longhorn-system
```

### Logs

```bash
# Tail pod logs
kubectl --kubeconfig ~/.foundry/kubeconfig logs -n monitoring -l app.kubernetes.io/name=grafana

# Follow logs
kubectl --kubeconfig ~/.foundry/kubeconfig logs -n monitoring -l app.kubernetes.io/name=grafana -f
```

### Restart Component

```bash
# Restart a deployment
kubectl --kubeconfig ~/.foundry/kubeconfig rollout restart deployment -n monitoring grafana
```

## Foundry CLI Usage

The foundry CLI can manage components if properly configured. Current status:

```bash
# Check component dependencies
foundry component list

# Dry-run install (checks dependencies)
foundry component install prometheus --dry-run

# Note: Some components may need SSH keys configured for host operations
```

## References

- [Foundry Documentation](https://github.com/catalystcommunity/foundry)
- [K3s Documentation](https://docs.k3s.io/)
- [Longhorn Documentation](https://longhorn.io/docs/)
- [Contour Documentation](https://projectcontour.io/)
- [Tailscale Kubernetes Operator](https://tailscale.com/k8s-operator)