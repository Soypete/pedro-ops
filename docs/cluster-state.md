# Cluster State Document

Last updated: 2025-07-21

## Current Cluster Status

### Nodes

| Hostname | IP | Role | CPU | Memory | Status |
|----------|-----|------|-----|--------|--------|
| blue1 | 100.81.89.62 | Control Plane | 4 cores | 16GB | Ready |
| blue2 | 100.125.196.1 | Worker | 4 cores | 16GB | Ready |
| refurb | 100.70.90.12 | Worker | 8 cores | 32GB | Ready |

### Resource Usage

| Node | CPU Usage | CPU % | Memory Usage | Memory % |
|------|-----------|-------|--------------|----------|
| blue1 | 521m | 13% | 6.8GB | 44% |
| blue2 | 460m | 11% | 10GB | 64% |
| refurb | 364m | 4% | 13GB | 41% |

### Active Namespaces (17)

| Namespace | Status | Purpose |
|-----------|--------|---------|
| default | Active | Kubernetes default |
| kube-system | Active | K8s system components |
| monitoring | Active | Prometheus, Loki, Grafana |
| tailscale | Active | Tailscale operator |
| longhorn-system | Active | Distributed storage |
| openbao | Active | Secrets management |
| openwebui | Active | AI web UI |
| chatbot | Active | Chatbot/mempalace workloads |
| kei | Active | ABAC engine |
| pedro | Active | Pedro Slack bot |
| pedrotag | Active | Discord/Slack integrations |
| cnpg-system | Active | CloudNativePG operator |
| external-dns | Active | DNS management |
| projectcontour | Active | Ingress controller |
| seaweedfs | Active | S3-compatible storage |
| velero | Active | Backup system |
| redditwatch | Active | Pedro agents: Reddit monitor, suggest, social, CFP (Helm release `pedro-agents`) |

### Deleted Namespaces

- `experiments` - deleted 2025-07-21 (was empty)
- `kitaru` - deleted 2025-07-21 (app no longer needed)
- `agents` - deleted 2025-07-21 (was empty)
- `pedrocli` - deleted 2025-07-21 (no longer needed)

### Deleted Airbyte Resources

The following were removed from `default` namespace on 2025-07-21:

**Deployments deleted:**
- eleduck-analytics-server
- eleduck-analytics-worker
- eleduck-analytics-cron
- eleduck-analytics-workload-launcher
- eleduck-analytics-connector-builder-server
- eleduck-analytics-temporal
- eleduck-analytics-webapp
- eleduck-analytics-workload-api-server
- release-name-server
- release-name-worker
- release-name-cron
- release-name-workload-launcher
- release-name-connector-builder-server
- release-name-temporal
- release-name-webapp
- release-name-workload-api-server

**StatefulSets deleted:**
- airbyte-db

**Services deleted:**
- airbyte-db-svc
- eleduck-analytics-airbyte-connector-builder-server-svc
- eleduck-analytics-airbyte-server-svc
- eleduck-analytics-airbyte-webapp-svc
- eleduck-analytics-temporal
- eleduck-analytics-workload-api-server-svc
- release-name-airbyte-connector-builder-server-svc
- release-name-airbyte-server-svc
- release-name-airbyte-webapp-svc
- release-name-temporal
- release-name-workload-api-server-svc

## Helm Deployments

Run `helm list -A` to see all deployed Helm charts.

## Persistent Volumes

Check with: `kubectl get pv` and `kubectl get pvc -A`

## Velero Backups

Check with: `velero backup get`