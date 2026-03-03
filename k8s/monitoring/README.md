# Monitoring Configuration

This directory contains custom monitoring configurations for the pedro-ops cluster.

## Contents

- `persistent-volumes.yaml` - PersistentVolumes for 2TB storage backend
- `servicemonitor-template.yaml` - Template for creating ServiceMonitors
- `prometheusrule-template.yaml` - Template for Prometheus alerting rules

## Persistent Storage

The 2TB drive on Worker-1 provides dedicated storage for:

| Component | Size | Path | Purpose |
|-----------|------|------|---------|
| OpenBAO | 50Gi | `/data/persistent-storage/openbao` | Secrets management |
| Prometheus | 200Gi | `/data/persistent-storage/prometheus` | Metrics (15d retention) |
| Loki | 100Gi | `/data/persistent-storage/loki` | Logs (7d retention) |
| Grafana | 10Gi | `/data/persistent-storage/grafana` | Dashboards |

### Applying Storage Configuration

```bash
# Apply PersistentVolumes and StorageClass
kubectl apply -f k8s/monitoring/persistent-volumes.yaml

# Verify PVs
kubectl get pv

# Check storage usage
ssh root@100.70.90.12 'du -sh /data/persistent-storage/*'
```

## Service Monitoring

### Creating a ServiceMonitor

1. Copy the template:
   ```bash
   cp k8s/monitoring/servicemonitor-template.yaml k8s/monitoring/my-app-servicemonitor.yaml
   ```

2. Edit the file:
   ```yaml
   metadata:
     name: my-app
     namespace: pedro-ops
   spec:
     selector:
       matchLabels:
         app: my-app
   ```

3. Apply:
   ```bash
   kubectl apply -f k8s/monitoring/my-app-servicemonitor.yaml
   ```

4. Verify in Prometheus:
   ```bash
   kubectl port-forward -n monitoring svc/prometheus-k8s 9090:9090
   # Open http://localhost:9090/targets
   ```

## Alerting Rules

### Creating Alert Rules

1. Copy the template:
   ```bash
   cp k8s/monitoring/prometheusrule-template.yaml k8s/monitoring/my-app-alerts.yaml
   ```

2. Customize rules for your application

3. Apply:
   ```bash
   kubectl apply -f k8s/monitoring/my-app-alerts.yaml
   ```

4. Verify in Prometheus:
   ```bash
   # Open http://localhost:9090/alerts
   ```

## Accessing Monitoring Services

### Grafana

```bash
# Get admin password
kubectl get secret -n monitoring grafana-admin-credentials \
  -o jsonpath='{.data.password}' | base64 -d

# Port-forward
kubectl port-forward -n monitoring svc/grafana 3000:3000

# Open http://localhost:3000
# Username: admin
```

### Prometheus

```bash
kubectl port-forward -n monitoring svc/prometheus-k8s 9090:9090
# Open http://localhost:9090
```

### Alertmanager

```bash
kubectl port-forward -n monitoring svc/alertmanager-main 9093:9093
# Open http://localhost:9093
```

## Storage Maintenance

### Check Storage Usage

```bash
# From local machine
ssh root@100.70.90.12 'df -h /data/persistent-storage'
ssh root@100.70.90.12 'du -sh /data/persistent-storage/*'

# From within cluster
kubectl exec -n monitoring prometheus-k8s-0 -- df -h /prometheus
```

### Backup Storage

```bash
# Create snapshot of 2TB drive
./scripts/backup-cluster.sh

# Backups stored in SeaweedFS S3: s3://pedro-ops-backups/
```

### Clean Up Old Data

Prometheus and Loki automatically clean up based on retention policies:
- Prometheus: 15 days
- Loki: 7 days

Manual cleanup if needed:

```bash
# Prometheus
kubectl exec -n monitoring prometheus-k8s-0 -- \
  promtool tsdb create-blocks-from openmetrics /prometheus

# Loki (compaction runs automatically)
kubectl logs -n monitoring loki-0 | grep compaction
```

## Troubleshooting

### PV Not Binding

```bash
# Check PV status
kubectl get pv

# Check PVC status
kubectl get pvc -A

# Describe PVC for events
kubectl describe pvc -n monitoring <pvc-name>

# Verify node labels
kubectl get nodes --show-labels | grep worker-1
```

### Storage Full

```bash
# Check usage
ssh root@100.70.90.12 'df -h /data/persistent-storage'

# Find largest directories
ssh root@100.70.90.12 'du -h /data/persistent-storage | sort -h | tail -20'

# Reduce retention if needed (edit Prometheus/Loki config)
```

### Metrics Not Appearing

```bash
# Check ServiceMonitor
kubectl get servicemonitor -A

# Check Prometheus targets
kubectl port-forward -n monitoring svc/prometheus-k8s 9090:9090
# Visit http://localhost:9090/targets

# Check service endpoints
kubectl get endpoints -n pedro-ops my-app
```

## References

- [Prometheus Operator](https://prometheus-operator.dev/)
- [Grafana Documentation](https://grafana.com/docs/)
- [Loki Documentation](https://grafana.com/docs/loki/latest/)
