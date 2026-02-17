# Pedro Ops - Kubernetes Cluster Infrastructure

Infrastructure as Code (IaC) repository for the pedro-ops Kubernetes cluster. This repository manages the complete infrastructure stack for AI workload hosting and GPU inference machine connectivity.

> **Note**: The original Go application code has been archived in the `archive/go-application` branch. This repository has been restructured to focus on Kubernetes infrastructure management.

## Cluster Overview

A production-ready 3-node Kubernetes cluster deployed with [Foundry CLI](https://github.com/catalystcommunity/foundry), featuring:

- **K3s**: Lightweight Kubernetes distribution
- **Tailscale Operator**: Secure connectivity to external GPU machine
- **Complete Observability Stack**: Prometheus, Loki, Grafana
- **Distributed Storage**: Longhorn with 2TB persistent backend
- **Service Mesh**: Contour ingress controller
- **Secrets Management**: OpenBAO (HashiCorp Vault fork)
- **Container Registry**: Zot (OCI-compliant)
- **DNS**: PowerDNS + Tailscale Magic DNS integration

## Cluster Architecture

### Node Topology

| Role | IP Address | Purpose |
|------|------------|---------|
| Control Plane | 100.81.89.62 | K8s control plane + infrastructure services |
| Worker 1 | 100.70.90.12 | Workloads + 2TB storage backend |
| Worker 2 | 100.125.196.1 | Workloads |
| Virtual IP | 100.81.89.100 | K8s API endpoint |

### Storage Layout

All persistent data is stored on a 2TB drive attached to Worker-1 at `/data/persistent-storage/`:

- **OpenBAO**: 50Gi (secrets management)
- **Prometheus**: 200Gi (15 days retention)
- **Loki**: 100Gi (7 days retention)
- **Grafana**: 10Gi (dashboards and config)
- **Longhorn**: Distributed storage across workers
- **SeaweedFS**: 500Gi S3-compatible object storage

### Network Architecture

- **Internal DNS**: PowerDNS (soypetetech.local domain)
- **External Connectivity**: Tailscale VPN
- **DNS Integration**: Split DNS (PowerDNS for cluster, Tailscale Magic DNS for external resources)
- **Ingress**: Contour (Gateway API controller)

## Quick Start

### Prerequisites

- 3 Linux nodes (Debian 11/12 or Ubuntu 22.04/24.04)
- SSH key-based access to all nodes
- Go 1.21+ (for Foundry CLI installation)
- kubectl and helm installed locally
- Tailscale account (free tier works)

### Installation

Follow the phased deployment approach:

```bash
# Phase 1: Pre-deployment verification
./scripts/phase1-verify-hosts.sh
./scripts/phase1-setup-storage.sh
./scripts/phase1-install-prerequisites.sh

# Phase 2: Install Foundry CLI
./scripts/phase2-install-foundry.sh

# Phase 3: Deploy Foundry stack
./scripts/phase3-deploy-foundry.sh

# Phase 4: Install Tailscale integration
export TS_CLIENT_ID="your_client_id"
export TS_CLIENT_SECRET="your_client_secret"
./scripts/phase4-install-tailscale.sh

# Configure kubectl access
export KUBECONFIG=~/.kube/pedro-ops-config
kubectl get nodes
```

See [docs/setup-guide.md](docs/setup-guide.md) for detailed instructions.

## Repository Structure

```
pedro-ops/
├── README.md                    # This file
├── CLAUDE.md                    # Project instructions for Claude Code
├── foundry/
│   ├── stack.yaml              # Foundry cluster configuration
│   └── README.md               # Foundry setup documentation
├── k8s/
│   ├── base/                   # Base Kubernetes manifests
│   ├── overlays/
│   │   └── production/         # Production-specific configs
│   ├── tailscale/              # Tailscale operator configs
│   └── monitoring/             # Custom monitoring configs
├── helm/                       # Helm charts for applications
├── scripts/                    # Operational automation scripts
│   ├── phase1-*.sh            # Pre-deployment scripts
│   ├── phase2-*.sh            # Foundry installation
│   ├── phase3-*.sh            # Stack deployment
│   ├── phase4-*.sh            # Tailscale integration
│   └── validate-*.sh          # Validation scripts
├── docs/                       # Documentation
│   ├── setup-guide.md         # Complete setup guide
│   ├── architecture.md        # Architecture documentation
│   ├── storage-setup.md       # Storage configuration and LVM setup
│   ├── troubleshooting.md     # Common issues and solutions
│   └── tailscale-setup.md     # Tailscale setup details
└── .github/
    └── workflows/              # CI/CD workflows
        ├── validate-manifests.yml
        └── deploy-production.yml
```

## Common Operations

### Access Cluster

```bash
# Set kubeconfig
export KUBECONFIG=~/.kube/pedro-ops-config

# View nodes
kubectl get nodes -o wide

# View all pods
kubectl get pods -A
```

### Access Services

```bash
# Get Grafana password
kubectl get secret -n monitoring grafana-admin-credentials -o jsonpath='{.data.password}' | base64 -d

# Port-forward to Grafana
kubectl port-forward -n monitoring svc/grafana 3000:3000

# Port-forward to Prometheus
kubectl port-forward -n monitoring svc/prometheus-k8s 9090:9090

# Access Zot registry
kubectl port-forward -n zot-system svc/zot 5000:5000
```

### Deploy Applications

```bash
# Apply base manifests
kubectl apply -k k8s/base

# Apply production overlays
kubectl apply -k k8s/overlays/production

# Install Helm charts
helm install my-app ./helm/my-app -n default
```

### Monitor Cluster

```bash
# Check Foundry stack status
foundry stack status

# Check component health
foundry component status k3s
foundry component status longhorn
foundry component status prometheus

# View storage usage
kubectl get pv
kubectl get pvc -A
ssh root@100.70.90.12 'du -sh /data/persistent-storage/*'
```

### Tailscale Operations

```bash
# Check Tailscale status
kubectl get pods -n tailscale
kubectl get connector -n tailscale

# Test connectivity to GPU machine
kubectl run test --image=nicolaka/netshoot -it --rm -- ping gpu-machine.your-tailnet.ts.net
```

## Development

### Adding New Applications

1. Create Helm chart in `helm/` directory
2. Add Kubernetes manifests to `k8s/base/`
3. Create production overlay in `k8s/overlays/production/`
4. Update CI/CD workflow in `.github/workflows/`
5. Document in `docs/`

### Modifying Infrastructure

1. Update `foundry/stack.yaml` configuration
2. Validate changes: `foundry config validate`
3. Apply changes: `foundry stack update`
4. Commit to version control

### Testing Changes

```bash
# Validate Kubernetes manifests
kubectl apply --dry-run=client -k k8s/overlays/production

# Lint YAML files
yamllint k8s/

# Test Helm charts
helm lint ./helm/my-app
helm template ./helm/my-app
```

## Backup and Disaster Recovery

### Automated Backups

Velero is configured for automated cluster backups:

```bash
# Create on-demand backup
velero backup create manual-backup-$(date +%Y%m%d)

# List backups
velero backup get

# Restore from backup
velero restore create --from-backup <backup-name>
```

### Storage Backups

```bash
# Backup 2TB drive data
./scripts/backup-cluster.sh

# Stored in SeaweedFS S3 bucket: s3://pedro-ops-backups/
```

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) for common issues and solutions.

### Quick Checks

```bash
# Check node health
kubectl get nodes
kubectl describe node <node-name>

# Check pod status
kubectl get pods -A | grep -v Running

# Check logs
kubectl logs -n <namespace> <pod-name>

# Check Foundry logs
foundry logs
```

## Security

- **Secrets Management**: All secrets stored in OpenBAO
- **Network Security**: Tailscale VPN for external connectivity
- **RBAC**: Kubernetes role-based access control configured
- **TLS**: Automatic certificate management via cert-manager
- **Pod Security**: Pod Security Standards enforced

## Monitoring and Observability

- **Metrics**: Prometheus (15 days retention on 2TB drive)
- **Logs**: Loki (7 days retention on 2TB drive)
- **Dashboards**: Grafana with pre-configured dashboards
- **Alerting**: Prometheus Alertmanager configured
- **Tracing**: (Coming soon) OpenTelemetry integration

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Resources

- [Foundry Documentation](https://github.com/catalystcommunity/foundry)
- [K3s Documentation](https://docs.k3s.io/)
- [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator)
- [Longhorn Documentation](https://longhorn.io/docs/)
- [Prometheus Operator](https://prometheus-operator.dev/)

## Support

For issues and questions:
- Open an issue in this repository
- Check [docs/troubleshooting.md](docs/troubleshooting.md)
- Review Foundry documentation

---

**Previous Version**: The Go application code has been preserved in the `archive/go-application` branch for reference.
