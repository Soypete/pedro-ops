# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with this Infrastructure as Code repository.

## Project Overview

Pedro Ops is a Kubernetes cluster infrastructure repository managing a production 3-node K3s cluster deployed via Foundry CLI. The cluster provides:

- Complete observability stack (Prometheus, Loki, Grafana)
- Tailscale integration for secure connectivity to external GPU inference machine
- Distributed storage with Longhorn on 2TB persistent backend
- Internal service mesh with Contour ingress controller
- Secrets management with OpenBAO
- Container registry with Zot
- DNS services via PowerDNS + Tailscale Magic DNS

## Repository Purpose

This is an Infrastructure as Code (IaC) repository containing:
- Cluster-wide Kubernetes manifests
- Foundry CLI configuration files
- Helm charts for application deployments
- Operational scripts and automation
- CI/CD workflows for validation and deployment
- Documentation for cluster management

> **Note**: The original Go application code has been archived in the `archive/go-application` branch. This repository focuses solely on infrastructure management.

## Cluster Architecture

### Node Topology
- **Control Plane**: 100.81.89.62 (K8s control plane + infrastructure services)
- **Worker 1**: 100.70.90.12 (workloads + 2TB storage backend)
- **Worker 2**: 100.125.196.1 (workloads)
- **Virtual IP**: 100.81.89.100 (K8s API endpoint)

### Storage Strategy
- 2TB drive on Worker-1 mounted at `/data/persistent-storage/`
- Longhorn distributed storage (2 replicas across workers)
- Dedicated persistent volumes for: OpenBAO, Prometheus, Loki, Grafana
- SeaweedFS for S3-compatible object storage

### Networking
- PowerDNS for internal cluster DNS (soypetetech.local)
- Tailscale Operator for secure external connectivity
- Split DNS: PowerDNS (internal) + Tailscale Magic DNS (external)
- Contour for ingress (Gateway API controller)

## Key Commands

### Foundry Operations

```bash
# Check stack status
foundry stack status

# Validate configuration
foundry stack validate
foundry config validate

# Install/update components
foundry component install <component>
foundry component restart <component>

# View logs
foundry logs
```

### Kubernetes Operations

```bash
# Set kubeconfig
export KUBECONFIG=~/.kube/pedro-ops-config

# Cluster operations
kubectl get nodes
kubectl get pods -A
kubectl get pv
kubectl get pvc -A

# Apply manifests
kubectl apply -k k8s/base
kubectl apply -k k8s/overlays/production

# Port-forward to services
kubectl port-forward -n monitoring svc/grafana 3000:3000
kubectl port-forward -n monitoring svc/prometheus-k8s 9090:9090
```

### Deployment Scripts

```bash
# Phase 1: Pre-deployment
./scripts/phase1-verify-hosts.sh
./scripts/phase1-setup-storage.sh
./scripts/phase1-install-prerequisites.sh

# Phase 2: Foundry installation
./scripts/phase2-install-foundry.sh

# Phase 3: Deploy stack
./scripts/phase3-deploy-foundry.sh

# Phase 4: Tailscale integration
export TS_CLIENT_ID="your_client_id"
export TS_CLIENT_SECRET="your_client_secret"
./scripts/phase4-install-tailscale.sh

# Validation
./scripts/validate-storage.sh
```

## Repository Conventions

### File Organization
- **foundry/**: Foundry CLI configuration and documentation
- **k8s/base/**: Base Kubernetes manifests (namespace, common resources)
- **k8s/overlays/production/**: Production-specific configurations
- **k8s/tailscale/**: Tailscale operator manifests
- **k8s/monitoring/**: Custom monitoring configurations
- **helm/**: Helm charts for application deployments
- **scripts/**: Operational automation scripts
- **docs/**: Architecture and operational documentation

### Naming Conventions
- Kubernetes resources: kebab-case (e.g., `my-service`, `worker-node-1`)
- Files: kebab-case with extension (e.g., `persistent-volumes.yaml`, `setup-cluster.sh`)
- Scripts: Descriptive names with phase prefix (e.g., `phase1-verify-hosts.sh`)
- Directories: lowercase with hyphens (e.g., `k8s`, `overlays`, `tailscale`)

### Configuration Management
- Use Kustomize for environment-specific configurations
- Store secrets in `.example` files, never commit actual secrets to git
- Document all infrastructure changes in Git commits with clear messages
- Follow semantic versioning for Helm charts

### Documentation Standards
- Update README.md for user-facing changes
- Update CLAUDE.md for developer guidance changes
- Document architectural decisions in `docs/architecture.md`
- Maintain troubleshooting guide in `docs/troubleshooting.md`
- Include inline comments in complex scripts

## Security Practices

- **Secrets**: Never commit secrets; use `.example` files for templates
- **Access**: SSH key-based authentication only
- **Credentials**: Store in OpenBAO, not in git
- **Tailscale**: Use OAuth secrets via environment variables
- **Kubernetes**: Follow RBAC best practices

## Common Tasks

### Adding a New Application

1. Create Helm chart in `helm/my-app/`
2. Add base manifests to `k8s/base/my-app/`
3. Create production overlay in `k8s/overlays/production/my-app/`
4. Update kustomization.yaml files
5. Add CI/CD validation
6. Document in README.md

### Modifying Infrastructure

1. Update `foundry/stack.yaml`
2. Validate: `foundry config validate`
3. Test in development environment first
4. Apply: `foundry stack update`
5. Verify: `foundry stack status`
6. Document changes

### Troubleshooting

1. Check pod status: `kubectl get pods -A`
2. View logs: `kubectl logs -n <namespace> <pod-name>`
3. Check Foundry: `foundry logs`
4. Verify storage: `kubectl get pv && kubectl get pvc -A`
5. Test connectivity: Deploy test pod with netshoot image
6. Consult `docs/troubleshooting.md`

## CI/CD Workflows

### Manifest Validation (`.github/workflows/validate-manifests.yml`)
- Runs on: Push to main/develop, Pull requests
- Validates: Kubernetes manifests, YAML linting, Kustomize builds
- Tools: kubectl, kustomize, yamllint

### Production Deployment (`.github/workflows/deploy-production.yml`)
- Runs on: Manual trigger or tag push
- Deploys: Production overlays to cluster
- Requires: Kubeconfig secret in GitHub

## Operational Guidelines

### Before Making Changes
1. Read existing code/configuration thoroughly
2. Understand dependencies and impacts
3. Test in non-production environment when possible
4. Validate manifests: `kubectl apply --dry-run=client`

### When Writing Scripts
- Add error handling: `set -euo pipefail`
- Include colored output for readability
- Provide clear progress indicators
- Add helpful error messages
- Make scripts idempotent when possible

### When Documenting
- Be concise but complete
- Include examples for complex operations
- Document the "why" not just the "what"
- Keep documentation in sync with code changes

## Integration with External Systems

### Tailscale
- Operator manages connectivity to GPU inference machine
- ACL policy controls access between cluster and external resources
- Magic DNS enables hostname-based resolution
- See `k8s/tailscale/README.md` for details

### GPU Inference Machine
- Connected via Tailscale with tag `tag:gpu-inference`
- Accessible from cluster pods via Tailscale DNS
- Network policy allows traffic from `tag:k8s-pedro-ops`
- See `docs/tailscale-integration.md` for setup

## Important Notes

- This is NOT a Go project; it's an IaC repository
- All Go application code has been archived
- Focus on Kubernetes manifests, Helm charts, and operational scripts
- Foundry CLI manages the cluster lifecycle
- Storage is critical: 2TB drive on Worker-1 for all persistent data
- Tailscale provides the only external connectivity path
