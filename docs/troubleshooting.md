# Troubleshooting Guide

Common issues and solutions for the pedro-ops Kubernetes cluster.

## Table of Contents

- [Deployment Issues](#deployment-issues)
- [Networking Problems](#networking-problems)
- [Storage Issues](#storage-issues)
- [Monitoring and Observability](#monitoring-and-observability)
- [Tailscale Connectivity](#tailscale-connectivity)
- [Performance Issues](#performance-issues)
- [Recovery Procedures](#recovery-procedures)

## Deployment Issues

### Foundry Stack Installation Fails

**Symptoms:**
- `foundry stack install` command fails
- Error messages about unreachable hosts
- Timeout errors

**Solutions:**

1. **Check SSH connectivity:**
   ```bash
   ./scripts/phase1-verify-hosts.sh
   ```

2. **Verify Foundry configuration:**
   ```bash
   foundry config validate
   foundry validate
   ```

3. **Check Foundry logs:**
   ```bash
   foundry logs
   ```

4. **Retry with specific component:**
   ```bash
   foundry component install k3s
   foundry component status k3s
   ```

5. **Complete reset if needed:**
   ```bash
   foundry stack uninstall
   # Fix underlying issues
   foundry stack install
   ```

### Pods Stuck in Pending State

**Symptoms:**
- Pods remain in `Pending` status
- `kubectl get pods -A` shows many pending pods

**Diagnosis:**

```bash
# Describe the pending pod
kubectl describe pod -n <namespace> <pod-name>

# Check events
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

**Common Causes:**

1. **Insufficient resources:**
   ```bash
   kubectl describe nodes
   # Look for resource pressure
   ```

   **Solution:** Add more nodes or reduce resource requests

2. **Storage issues:**
   ```bash
   kubectl get pv
   kubectl get pvc -A
   ```

   **Solution:** Create PersistentVolumes or fix storage backend

3. **Node selector mismatch:**
   ```bash
   kubectl get pod <pod-name> -o yaml | grep nodeSelector
   kubectl get nodes --show-labels
   ```

   **Solution:** Update node labels or pod selector

### Node Not Ready

**Symptoms:**
- `kubectl get nodes` shows node as `NotReady`
- Pods not scheduling to the node

**Diagnosis:**

```bash
kubectl describe node <node-name>
```

**Solutions:**

1. **Restart K3s on the node:**
   ```bash
   ssh root@<node-ip> 'systemctl restart k3s'
   # or for workers:
   ssh root@<node-ip> 'systemctl restart k3s-agent'
   ```

2. **Check kubelet logs:**
   ```bash
   ssh root@<node-ip> 'journalctl -u k3s -f'
   ```

3. **Verify network connectivity:**
   ```bash
   ssh root@<node-ip> 'ping -c 3 100.81.89.62'  # Control plane
   ```

4. **Check disk space:**
   ```bash
   ssh root@<node-ip> 'df -h'
   ```

## Networking Problems

### Cannot Access Services via Port-Forward

**Symptoms:**
- `kubectl port-forward` command hangs or fails
- Cannot access services on localhost

**Solutions:**

1. **Check if pod is running:**
   ```bash
   kubectl get pods -n <namespace> -l app=<app-name>
   ```

2. **Verify service exists:**
   ```bash
   kubectl get svc -n <namespace>
   ```

3. **Check endpoints:**
   ```bash
   kubectl get endpoints -n <namespace> <service-name>
   ```

4. **Try different port-forward syntax:**
   ```bash
   # Use pod directly
   kubectl port-forward -n <namespace> pod/<pod-name> 8080:8080

   # Use deployment
   kubectl port-forward -n <namespace> deployment/<deployment-name> 8080:8080
   ```

### External DNS Resolution Failing in Application Pods

**Symptoms:**
- Application pods fail with `UnknownHostException` or `bad address` errors
- Test pods (busybox, netshoot) CAN resolve external hostnames
- Specific to certain container images (Java-based apps, nc/netcat utilities)

**Example Errors:**
```
java.net.UnknownHostException: aws-0-us-west-1.pooler.supabase.com
nc: bad address 'aws-0-us-west-1.pooler.supabase.com'
```

**Root Cause:**
Some container images have DNS resolution issues with CoreDNS forwarding, particularly Java applications and certain utilities.

**Solution: Use hostAliases**

Add hostAliases to pod specifications to bypass DNS resolution:

```yaml
# In Helm values file
temporal:
  hostAliases:
    - ip: "52.8.172.168"  # Get IP with: dig +short hostname
      hostnames:
        - "aws-0-us-west-1.pooler.supabase.com"

metabase:
  hostAliases:
    - ip: "52.8.172.168"
      hostnames:
        - "aws-0-us-west-1.pooler.supabase.com"
```

This adds entries to `/etc/hosts` in the pod, bypassing DNS entirely.

**Verification:**
```bash
# Check /etc/hosts in the pod
kubectl exec -n <namespace> <pod-name> -- cat /etc/hosts

# Should show:
# 52.8.172.168    aws-0-us-west-1.pooler.supabase.com
```

### Pod-to-Pod Communication Failing

**Symptoms:**
- Pods cannot communicate with each other
- DNS resolution fails within cluster

**Diagnosis:**

```bash
# Test DNS resolution
kubectl run test --image=nicolaka/netshoot -it --rm -- nslookup kubernetes.default.svc.cluster.local

# Test connectivity to service
kubectl run test --image=nicolaka/netshoot -it --rm -- curl http://my-service.my-namespace.svc.cluster.local
```

**Solutions:**

1. **Check CoreDNS:**
   ```bash
   kubectl get pods -n kube-system -l k8s-app=kube-dns
   kubectl logs -n kube-system -l k8s-app=kube-dns
   ```

2. **Restart CoreDNS:**
   ```bash
   kubectl rollout restart deployment/coredns -n kube-system
   ```

3. **Check NetworkPolicies:**
   ```bash
   kubectl get networkpolicies -A
   kubectl describe networkpolicy -n <namespace> <policy-name>
   ```

4. **Verify CNI (Flannel):**
   ```bash
   kubectl get pods -n kube-system -l app=flannel
   ```

### Ingress Not Working

**Symptoms:**
- Cannot access applications via ingress
- External traffic not reaching pods

**Diagnosis:**

```bash
# Check Contour pods
kubectl get pods -n projectcontour

# Check HTTPRoute or Ingress resources
kubectl get httproute -A
kubectl get ingress -A

# Check Contour logs
kubectl logs -n projectcontour -l app=contour
```

**Solutions:**

1. **Verify HTTPRoute configuration:**
   ```bash
   kubectl describe httproute -n <namespace> <httproute-name>
   ```

2. **Check backend service:**
   ```bash
   kubectl get svc -n <namespace> <service-name>
   kubectl get endpoints -n <namespace> <service-name>
   ```

3. **Restart Contour:**
   ```bash
   kubectl rollout restart deployment/contour -n projectcontour
   ```

## Storage Issues

### 2TB Drive Not Mounted

**Symptoms:**
- `df -h` doesn't show `/data/persistent-storage`
- Storage directories missing

**Solutions:**

```bash
# Check if drive is mounted
ssh root@100.70.90.12 'mount | grep /data/persistent-storage'

# If not mounted, mount it
ssh root@100.70.90.12 'mount /dev/sdb /data/persistent-storage'

# Check /etc/fstab
ssh root@100.70.90.12 'cat /etc/fstab | grep persistent-storage'

# Verify mount persists after reboot
ssh root@100.70.90.12 'mount -a'
```

### PersistentVolume Not Binding

**Symptoms:**
- PVC stuck in `Pending` state
- PV shows as `Available` but not `Bound`

**Diagnosis:**

```bash
kubectl get pv
kubectl get pvc -A
kubectl describe pvc -n <namespace> <pvc-name>
```

**Solutions:**

1. **Check PV/PVC compatibility:**
   - Storage size (PVC request ≤ PV capacity)
   - Access modes match
   - StorageClass matches

2. **Verify node affinity:**
   ```bash
   kubectl get pv <pv-name> -o yaml | grep -A 10 nodeAffinity
   kubectl get nodes --show-labels
   ```

3. **Check local path exists:**
   ```bash
   ssh root@100.70.90.12 'ls -la /data/persistent-storage/prometheus'
   ```

4. **Apply PV manually if needed:**
   ```bash
   kubectl apply -f k8s/monitoring/persistent-volumes.yaml
   ```

### Longhorn Volume Issues

**Symptoms:**
- Longhorn volumes not creating
- Volume stuck in `Creating` state

**Diagnosis:**

```bash
kubectl get pods -n longhorn-system
kubectl logs -n longhorn-system -l app=longhorn-manager
```

**Solutions:**

1. **Check Longhorn UI:**
   ```bash
   kubectl port-forward -n longhorn-system svc/longhorn-frontend 8000:80
   # Open http://localhost:8000
   ```

2. **Verify node eligibility:**
   ```bash
   # Longhorn requires all nodes to have storage
   ssh root@100.70.90.12 'df -h /data/persistent-storage/longhorn'
   ssh root@100.125.196.1 'df -h /var/lib/longhorn'  # Default path
   ```

3. **Check for NFS client (required for ReadWriteMany volumes):**
   ```bash
   # Longhorn uses NFS for RWX volumes - verify nfs-common is installed
   ssh root@<node-ip> 'which mount.nfs'

   # If not installed, install on all nodes:
   for host in 100.81.89.62 100.70.90.12 100.125.196.1; do
     ssh root@$host 'apt-get update && apt-get install -y nfs-common'
   done
   ```

   **Note:** RWX volumes will fail to mount with "bad option" errors if nfs-common is missing.

4. **Restart Longhorn manager:**
   ```bash
   kubectl rollout restart deployment/longhorn-driver-deployer -n longhorn-system
   ```

## Monitoring and Observability

### Grafana Not Accessible

**Symptoms:**
- Cannot access Grafana UI
- Port-forward fails or times out

**Solutions:**

1. **Check Grafana pod:**
   ```bash
   kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana
   kubectl logs -n monitoring -l app.kubernetes.io/name=grafana
   ```

2. **Verify service:**
   ```bash
   kubectl get svc -n monitoring grafana
   ```

3. **Reset admin password:**
   ```bash
   kubectl get secret -n monitoring grafana-admin-credentials \
     -o jsonpath='{.data.password}' | base64 -d
   echo
   ```

4. **Restart Grafana:**
   ```bash
   kubectl rollout restart deployment/grafana -n monitoring
   ```

### Prometheus Not Scraping Metrics

**Symptoms:**
- Metrics not appearing in Prometheus
- Targets showing as `Down` in Prometheus UI

**Diagnosis:**

```bash
# Port-forward to Prometheus
kubectl port-forward -n monitoring svc/prometheus-k8s 9090:9090

# Check targets: http://localhost:9090/targets
```

**Solutions:**

1. **Verify ServiceMonitor:**
   ```bash
   kubectl get servicemonitor -A
   kubectl describe servicemonitor -n <namespace> <servicemonitor-name>
   ```

2. **Check service labels:**
   ```bash
   # ServiceMonitor selector must match Service labels
   kubectl get svc -n <namespace> <service-name> --show-labels
   ```

3. **Verify metrics endpoint:**
   ```bash
   kubectl run test --image=nicolaka/netshoot -it --rm -- \
     curl http://<service-name>.<namespace>.svc.cluster.local:<port>/metrics
   ```

4. **Check Prometheus logs:**
   ```bash
   kubectl logs -n monitoring prometheus-k8s-0
   ```

### Loki Not Receiving Logs

**Symptoms:**
- No logs in Grafana Explore
- Promtail pods not running

**Diagnosis:**

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail
kubectl logs -n monitoring -l app.kubernetes.io/name=promtail
```

**Solutions:**

1. **Verify Promtail DaemonSet:**
   ```bash
   kubectl get daemonset -n monitoring promtail
   kubectl describe daemonset -n monitoring promtail
   ```

2. **Check Loki endpoint:**
   ```bash
   kubectl get svc -n monitoring loki
   ```

3. **Test Loki API:**
   ```bash
   kubectl port-forward -n monitoring svc/loki 3100:3100
   curl http://localhost:3100/ready
   ```

4. **Restart Promtail:**
   ```bash
   kubectl rollout restart daemonset/promtail -n monitoring
   ```

## Tailscale Connectivity

### Tailscale Operator Not Starting

**Symptoms:**
- Tailscale operator pod in `CrashLoopBackOff`
- Cannot connect to Tailscale network

**Diagnosis:**

```bash
kubectl get pods -n tailscale
kubectl logs -n tailscale -l app=tailscale-operator
kubectl describe pod -n tailscale -l app=tailscale-operator
```

**Solutions:**

1. **Verify OAuth credentials:**
   ```bash
   kubectl get secret -n tailscale tailscale-operator-oauth -o yaml
   ```

   Re-create if incorrect:
   ```bash
   kubectl delete secret -n tailscale tailscale-operator-oauth
   export TS_CLIENT_ID="your_client_id"
   export TS_CLIENT_SECRET="your_client_secret"
   ./scripts/phase4-install-tailscale.sh
   ```

2. **Check Tailscale ACL policy:**
   - Go to https://login.tailscale.com/admin/acls
   - Verify tags and permissions are correct

3. **Reinstall operator:**
   ```bash
   helm uninstall tailscale-operator -n tailscale
   ./scripts/phase4-install-tailscale.sh
   ```

### Cannot Reach GPU Machine from Cluster

**Symptoms:**
- Ping to GPU machine fails from pods
- DNS resolution fails for `.ts.net` domains

**Diagnosis:**

```bash
# Test DNS resolution
kubectl run test --image=nicolaka/netshoot -it --rm -- \
  nslookup gpu-machine.your-tailnet.ts.net

# Test connectivity
kubectl run test --image=nicolaka/netshoot -it --rm -- \
  ping gpu-machine.your-tailnet.ts.net
```

**Solutions:**

1. **Verify GPU machine is on tailnet:**
   - Check https://login.tailscale.com/admin/machines
   - Ensure GPU machine is online and tagged with `tag:gpu-inference`

2. **Check connector status:**
   ```bash
   kubectl get connector -n tailscale
   kubectl describe connector -n tailscale gpu-inference-connector
   ```

3. **Verify routes are approved:**
   - Go to https://login.tailscale.com/admin/machines
   - Find pedro-ops connector
   - Click "Approve" for advertised routes

4. **Check CoreDNS configuration:**
   ```bash
   kubectl get configmap coredns -n kube-system -o yaml | grep ts.net
   ```

   Should show:
   ```yaml
   ts.net:53 {
     forward . <tailscale-dns-ip>
   }
   ```

5. **Restart CoreDNS:**
   ```bash
   kubectl rollout restart deployment/coredns -n kube-system
   ```

## Performance Issues

### High CPU/Memory Usage

**Diagnosis:**

```bash
# Check node resources
kubectl top nodes

# Check pod resources
kubectl top pods -A

# Describe node for pressure indicators
kubectl describe node <node-name>
```

**Solutions:**

1. **Identify resource-hungry pods:**
   ```bash
   kubectl top pods -A --sort-by=cpu
   kubectl top pods -A --sort-by=memory
   ```

2. **Adjust resource limits:**
   ```yaml
   resources:
     limits:
       cpu: 500m
       memory: 512Mi
     requests:
       cpu: 100m
       memory: 128Mi
   ```

3. **Scale down non-critical workloads:**
   ```bash
   kubectl scale deployment/<name> --replicas=1 -n <namespace>
   ```

4. **Add more worker nodes** if consistently at capacity

### Slow Storage Performance

**Symptoms:**
- High latency for disk I/O
- Applications slow when accessing persistent volumes

**Diagnosis:**

```bash
# Check disk I/O on Worker-1
ssh root@100.70.90.12 'iostat -x 5 3'

# Check Longhorn volume health
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8000:80
# Open http://localhost:8000 and check volume health
```

**Solutions:**

1. **Check disk space:**
   ```bash
   ssh root@100.70.90.12 'df -h /data/persistent-storage'
   ```

2. **Reduce Prometheus/Loki retention:**
   Edit retention in Foundry stack.yaml and redeploy

3. **Clean up old data:**
   ```bash
   # Let Prometheus compact
   kubectl exec -n monitoring prometheus-k8s-0 -- \
     promtool tsdb create-blocks-from openmetrics /prometheus
   ```

4. **Consider adding SSD if using HDD**

## Recovery Procedures

### Complete Cluster Reset

**When to use:** Cluster is completely broken and unrecoverable

```bash
# 1. Uninstall Foundry stack
foundry stack uninstall

# 2. Clean up nodes
for host in 100.81.89.62 100.70.90.12 100.125.196.1; do
  ssh root@$host '/usr/local/bin/k3s-uninstall.sh || /usr/local/bin/k3s-agent-uninstall.sh || true'
done

# 3. Clean up persistent data (OPTIONAL - deletes all data!)
ssh root@100.70.90.12 'rm -rf /data/persistent-storage/{openbao,longhorn,prometheus,loki,grafana}/*'

# 4. Re-deploy from Phase 2
./scripts/phase2-install-foundry.sh
```

### Restore from Backup (Velero)

**When to use:** Data loss or cluster corruption

```bash
# List available backups
velero backup get

# Restore from specific backup
velero restore create --from-backup <backup-name>

# Monitor restore progress
velero restore describe <restore-name>
```

### Recover Single Component

**When to use:** Specific component (e.g., Prometheus) is broken

```bash
# Restart component
foundry component restart prometheus

# If that fails, reinstall
foundry component uninstall prometheus
foundry component install prometheus
```

## Getting Help

If issues persist:

1. **Check logs thoroughly:**
   ```bash
   foundry logs
   kubectl logs -n <namespace> <pod-name>
   ```

2. **Collect diagnostic information:**
   ```bash
   kubectl get pods -A
   kubectl get pv
   kubectl get pvc -A
   kubectl get events -A --sort-by='.lastTimestamp'
   foundry stack status
   ```

3. **Review documentation:**
   - [Setup Guide](setup-guide.md)
   - [Architecture](architecture.md)
   - Foundry docs: https://github.com/catalystcommunity/foundry

4. **Open an issue** in the repository with:
   - Problem description
   - Steps to reproduce
   - Relevant logs
   - Environment details
