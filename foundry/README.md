# Foundry Configuration

This directory contains the Foundry CLI configuration for the pedro-ops Kubernetes cluster.

## Overview

Foundry is used to deploy a complete K3s cluster with:
- **K3s**: Lightweight Kubernetes distribution
- **OpenBAO**: Secrets management (HashiCorp Vault fork)
- **PowerDNS**: Internal DNS for cluster services
- **Zot**: OCI-compliant container registry
- **Gateway API**: Ingress controller (Contour)
- **Cert-Manager**: TLS certificate management
- **Longhorn**: Distributed block storage
- **SeaweedFS**: S3-compatible object storage
- **Prometheus**: Metrics collection
- **Loki**: Log aggregation
- **Grafana**: Observability dashboards

## Configuration File

`stack.yaml` - Main Foundry configuration file

### Cluster Topology

- **Control Plane**: 100.81.89.62
  - Runs K8s control plane components
  - Hosts infrastructure services (OpenBAO, PowerDNS, Zot)
- **Worker 1**: 100.70.90.12
  - 2TB persistent storage backend
  - Hosts Longhorn storage volumes
- **Worker 2**: 100.125.196.1
  - Additional compute capacity
- **Virtual IP**: 100.81.89.100
  - K8s API endpoint

### Storage Strategy

All persistent data is stored on the 2TB drive attached to Worker-1 at `/data/persistent-storage/`:

- OpenBAO: 50Gi
- Prometheus: 200Gi (15 days retention)
- Loki: 100Gi (7 days retention)
- Grafana: 10Gi
- Longhorn: Distributed storage across workers
- SeaweedFS: 500Gi for S3-compatible object storage

## Installation

### Prerequisites

1. Complete Phase 1 verification:
   ```bash
   ./scripts/phase1-verify-hosts.sh
   ./scripts/phase1-setup-storage.sh
   ./scripts/phase1-install-prerequisites.sh
   ```

2. Install Foundry CLI (see Phase 2 instructions)

### Deploy Stack

```bash
# Copy configuration to Foundry directory
cp foundry/stack.yaml ~/.foundry/stack.yaml

# Add hosts to Foundry
foundry host add
# control-plane: 100.81.89.62, user: root
# worker-1: 100.70.90.12, user: root
# worker-2: 100.125.196.1, user: root

# Configure hosts
foundry host configure control-plane
foundry host configure worker-1
foundry host configure worker-2

# Validate configuration
foundry config validate
foundry validate

# Install the stack
foundry stack install

# Monitor progress
foundry stack status
```

### Post-Installation

```bash
# Get kubeconfig
foundry kubeconfig > ~/.kube/pedro-ops-config
export KUBECONFIG=~/.kube/pedro-ops-config

# Verify cluster
kubectl get nodes
kubectl get pods -A

# Access Grafana
kubectl get secret -n monitoring grafana-admin-credentials -o jsonpath='{.data.password}' | base64 -d
kubectl port-forward -n monitoring svc/grafana 3000:3000
```

## Troubleshooting

### Check Foundry logs
```bash
foundry logs
```

### Check component status
```bash
foundry component status openbao
foundry component status k3s
foundry component status longhorn
```

### Restart a component
```bash
foundry component restart <component-name>
```

### Uninstall stack (WARNING: Destructive)
```bash
foundry stack uninstall
```

## References

- [Foundry Documentation](https://github.com/catalystcommunity/foundry)
- [K3s Documentation](https://docs.k3s.io/)
- [Longhorn Documentation](https://longhorn.io/docs/)
