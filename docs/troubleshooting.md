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

### Cluster Not Accessible Remotely (Tailscale)

**Symptoms:**
- `kubectl` commands timeout with `dial tcp 10.0.0.11:6443: i/o timeout`
- Gateway API install fails with connection errors
- Cluster works locally but not via Tailscale VPN

**Root Cause:**
The kubeconfig and node join commands use the VIP (10.0.0.11) which is not accessible over the Tailscale network. The cluster must use the control plane's Tailscale IP for remote access.

**Diagnosis:**

```bash
# Check current kubeconfig server
grep "server:" ~/.foundry/kubeconfig

# Should show: server: https://100.81.89.62:6443 (Tailscale IP)
# Not: server: https://10.0.0.11:6443 (VIP - inaccessible remotely)
```

**Solution (Foundry fix):**

The fix is in branch `feat/use-tailscale-ip-in-kubeconfig`:
1. Modified `ModifyKubeconfigServer` to accept serverAddress parameter
2. Changed cluster init to use `firstHost.Address` instead of `cfg.Cluster.VIP`
3. Added `getControlPlaneAddress()` helper in node_add.go

**Workaround (manual fix):**

```bash
# Fix existing kubeconfig
sed -i 's/10.0.0.11/100.81.89.62/g' ~/.foundry/kubeconfig

# Or regenerate by running cluster init with fixed binary
/tmp/foundry cluster init
```

**Prevention:**
Ensure the Foundry fix is merged and deployed before cluster setup when using Tailscale for remote access.

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
# Identify where the affected workload and CoreDNS are running
kubectl get pods -n <namespace> -o wide
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide

# Test DNS resolution
kubectl run test --image=nicolaka/netshoot -it --rm -- nslookup kubernetes.default.svc.cluster.local

# Test connectivity to service
kubectl run test --image=nicolaka/netshoot -it --rm -- curl http://my-service.my-namespace.svc.cluster.local

# Confirm that the Service has ready backends
kubectl get service,endpoints,endpointslices -n <namespace> <service-name> -o wide
```

From an existing application pod, compare its DNS path with the Service IP. A
DNS-name failure combined with a successful direct Service-IP connection means
the application and backend are reachable and the fault is on the DNS path:

```bash
kubectl exec -n <namespace> <pod> -- getent hosts <service>.<namespace>.svc.cluster.local
kubectl exec -n <namespace> <pod> -- nc -vz <service-cluster-ip> <port>
```

If the application and backend share a node but CoreDNS is on another node,
same-node success plus DNS failure strongly indicates broken cross-node CNI
traffic. Do not work around this by committing a Service IP: ClusterIPs and pod
endpoints are implementation details that can change on a rebuild.

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
   kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" node="}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{end}{" flannel="}{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip}{"\n"}{end}'
   ```

   All Flannel endpoints must use the physical LAN:

   ```text
   blue1  node=192.168.1.185 flannel=192.168.1.185
   blue2  node=192.168.1.97  flannel=192.168.1.97
   refurb node=192.168.1.253 flannel=192.168.1.253
   ```

   The API VIP `10.0.0.11` must never appear as a Flannel endpoint. On
   2026-08-05, blue1 advertised that VIP and broke cross-node pod traffic. DNS
   appeared unhealthy because CoreDNS ran on blue1 while affected workloads ran
   on refurb. Direct same-node Service IP connections continued to work.

5. **Distinguish the DNS layers:**

   - CoreDNS resolves Kubernetes names such as `*.svc.cluster.local`.
   - PowerDNS is the Foundry `dns` component for managed/internal zones.
   - Tailscale MagicDNS resolves tailnet machine and `*.ts.net` names.

   An unhealthy `foundry stack status` DNS recursor does not by itself explain
   failures to resolve Kubernetes Service names. Check the Flannel path to
   CoreDNS as shown above.

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

### Longhorn Using Wrong Disk (Local vs Mounted)

**Symptoms:**
- Longhorn shows only ~100GB available on nodes instead of 1.5TB
- PVCs stuck in `ContainerCreating` with volume attachment failures
- Volumes show `detached` + `faulted` state
- Error: `insufficient storage;precheck new replica failed`

**Diagnosis:**

```bash
# Check Longhorn node disk status
kubectl get nodes.longhorn.io -n longhorn-system -o json | jq '.items[] | {node: .metadata.name, disks: .status.diskStatus}'

# Check available storage per node
kubectl get nodes.longhorn.io -n longhorn-system -o json | jq '.items[] | .status.diskStatus | to_entries[] | {disk: .key, available: .value.storageAvailable, maximum: .value.storageMaximum}'
```

**Root Cause:**
By default, Longhorn uses `/var/lib/longhorn` which is on the OS disk (typically 512GB NVMe). The 2TB mounted drive at `/data/persistent-storage` is not automatically used.

**Solutions:**

1. **Add the 2TB disk to Longhorn:**
   ```bash
   # Get the node name
   kubectl get nodes.longhorn.io -n longhorn-system
   
   # Patch the node to add the 2TB disk
   kubectl patch nodes.longhorn.io <node-name> -n longhorn-system \
     --type='json' -p='[{"op": "add", "path": "/spec/disks/data-disk", "value": {"allowScheduling": true, "diskType": "filesystem", "path": "/data/persistent-storage", "storageReserved": 150000000000, "tags": []}}]'
   ```

2. **Verify the disk is added:**
   ```bash
   kubectl get nodes.longhorn.io <node-name> -n longhorn-system -o json | jq '.status.diskStatus'
   ```

3. **If volumes are stuck (faulted), delete and recreate:**
   ```bash
   # Delete stuck volume
   kubectl delete volumes.longhorn.io <volume-name> -n longhorn-system
   
   # Delete the stuck pod
   kubectl delete pod <pod-name> -n <namespace>
   
   # Recreate the deployment/pvc
   kubectl apply -f <deployment.yaml>
   ```

4. **Disable the small local disk to prevent Longhorn using it:**
   ```bash
   kubectl patch nodes.longhorn.io <node-name> -n longhorn-system \
     --type='json' -p='[{"op": "replace", "path": "/spec/disks/default-disk-<uuid>/allowScheduling", "value": false}]'
   ```

**Prevention:**
When setting up a new cluster, ensure Longhorn is configured to use the mounted storage path from the start:
- Edit the Longhorn StorageClass or node disk configuration before deploying workloads
- Verify disk configuration with `kubectl get nodes.longhorn.io -o json | jq '.status.diskStatus'`

### Prometheus CrashLoopBackOff — "no space left on device"

**Symptoms:**
- `prometheus-kube-prometheus-stack-prometheus-0` in `CrashLoopBackOff` with a very high restart count.
- Container log ends with:
  `Error running goroutines from run.Group err="opening storage failed: open /prometheus/wal/00001713: no space left on device"`

**Root cause (as seen 2026-07-01):**
The Prometheus PVC was bound at only **10Gi**, while the Prometheus CR was configured with `retentionSize: 160GB` and `storage: 200Gi`. Two compounding problems:
1. Editing `spec.storage` on the Prometheus CR does **not** resize an existing PVC — the StatefulSet `volumeClaimTemplate` is immutable, so the 200Gi request never took effect and the volume stayed 10Gi.
2. `retentionSize` (160GB) was far larger than the actual disk (10Gi), so Prometheus never pruned and filled the volume until it crashed.
3. The volume's Longhorn replica had also landed on the **small `/var/lib/longhorn` default disk (105GB)** on `refurb`, not the **1.6TB `data-disk` (`/data/persistent-storage`)** — so even a resize couldn't reach 200Gi. (Longhorn's default disk was still schedulable and untagged; see "Longhorn Using Wrong Disk" above.)

**Diagnosis:**
```bash
export KUBECONFIG=~/.foundry/kubeconfig
kubectl config use-context default

# Confirm the crash reason
kubectl logs prometheus-kube-prometheus-stack-prometheus-0 -n monitoring -c prometheus --tail=5

# Compare CR intent vs actual PVC size (the mismatch is the bug)
kubectl get prometheus -n monitoring \
  -o jsonpath='retention={.items[0].spec.retention} retentionSize={.items[0].spec.retentionSize} storage={.items[0].spec.storage.volumeClaimTemplate.spec.resources.requests.storage}{"\n"}'
kubectl get pvc -n monitoring \
  prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0 \
  -o jsonpath='request={.spec.resources.requests.storage} capacity={.status.capacity.storage}{"\n"}'

# Which Longhorn disk is the replica on? (442d3905… = 1.6TB data-disk, 14e39fb2… = small default disk)
VOL=$(kubectl get pvc -n monitoring prometheus-...-prometheus-0 -o jsonpath='{.spec.volumeName}')
kubectl get replicas.longhorn.io -n longhorn-system -l longhornvolume=$VOL \
  -o jsonpath='{.items[0].spec.nodeID} {.items[0].spec.diskID}{"\n"}'
```

**Fix (recreate the volume empty on the 2TB data-disk):**
An in-place resize/replica-migrate fails here: the rebuild can't sync while Prometheus crash-loops (attached), and Longhorn discards the incomplete replica when the volume detaches. Because the TSDB was already full/corrupt, the clean fix is to recreate the volume empty on the big disk. **This loses existing metric history.**
```bash
# 1. Steer new volumes to the 2TB disk: disable scheduling on refurb's small default disk
kubectl patch nodes.longhorn.io refurb -n longhorn-system --type=merge \
  -p '{"spec":{"disks":{"default-disk-<uuid>":{"allowScheduling":false,"path":"/var/lib/longhorn"}}}}'

# 2. Make sure the Prometheus CR requests the size you want (200Gi here) and a sane retentionSize (<= disk)
kubectl patch prometheus kube-prometheus-stack-prometheus -n monitoring --type=merge \
  -p '{"spec":{"retentionSize":"160GB"}}'   # storage was already 200Gi

# 3. Scale Prometheus to 0 (detach the volume)
kubectl patch prometheus kube-prometheus-stack-prometheus -n monitoring --type=merge -p '{"spec":{"replicas":0}}'
# wait until the pod is gone and the Longhorn volume shows state=detached

# 4. Delete the old PVC (Delete reclaim policy removes the PV + Longhorn volume too)
kubectl delete pvc -n monitoring \
  prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0

# 5. Scale back to 1 — the operator recreates a fresh 200Gi PVC, which lands on the
#    only schedulable disk (the 1.6TB data-disk).
kubectl patch prometheus kube-prometheus-stack-prometheus -n monitoring --type=merge -p '{"spec":{"replicas":1}}'

# 6. Verify: pod 2/2 Running with 0 restarts, volume 200Gi healthy on disk 442d3905… (refurb data-disk)
kubectl get pod prometheus-kube-prometheus-stack-prometheus-0 -n monitoring
```

**Notes / gotchas:**
- If you try a replica-migrate instead, note Longhorn `replica-soft-anti-affinity` defaults to `false` (hard) — it won't place two replicas of one volume on the same node, so you can't build a second replica on refurb while one already lives there. If you temporarily flip it to `true`, **set it back to `false`** afterwards.
- After this fix, refurb's small `/var/lib/longhorn` disk is left `allowScheduling=false` on purpose so all Longhorn volumes use the 2TB `data-disk`. See `docs/storage-setup.md`.

### Loki stuck in ContainerCreating — "PersistentVolume is marked for deletion"

**Symptoms:**
- `loki-0` stuck `Pending`/`ContainerCreating` for a very long time (seen 41 days).
- Events show `FailedAttachVolume ... PersistentVolume "pvc-…" is marked for deletion` repeating thousands of times.

**Root cause (2026-07-01):**
The Loki PV **and** its PVC (`storage-loki-0`) both had a `deletionTimestamp` set (a delete was started ~2026-05-19) but were stuck on finalizers, while the underlying Longhorn volume had **already been deleted**. So the pod kept trying to attach a volume whose backing storage no longer existed. No data to preserve.

**Fix (clear the half-deleted PV/PVC, let Loki reprovision):**
```bash
export KUBECONFIG=~/.foundry/kubeconfig; kubectl config use-context default
PV=$(kubectl get pvc storage-loki-0 -n monitoring -o jsonpath='{.spec.volumeName}')

# Remove the stuck finalizers so the pending deletions complete
kubectl patch pv $PV --type=merge -p '{"metadata":{"finalizers":null}}'
kubectl patch pvc storage-loki-0 -n monitoring --type=merge -p '{"metadata":{"finalizers":null}}'

# Delete the stuck pod so the StatefulSet reprovisions a fresh PVC
kubectl delete pod loki-0 -n monitoring
```

**Then: "NoSuchBucket" from the compactor.**
Once the volume was fixed, `loki-0` crash-looped with:
`init compactor: failed to init delete store: failed to get s3 object: NoSuchBucket: The specified bucket does not exist`.
Loki stores chunks/index in a SeaweedFS S3 bucket named `loki` (per `stack.yaml`), and **the bucket didn't exist**. SeaweedFS returns `NoSuchBucket` (not `NoSuchKey`) on a GetObject against an empty/missing path, which Loki's compactor treats as fatal.

Create the bucket, then restart until it populates:
```bash
# List buckets / create the loki bucket via weed shell in the filer pod
kubectl exec -n seaweedfs seaweedfs-filer-0 -- sh -c 'echo "s3.bucket.list" | weed shell'
kubectl exec -n seaweedfs seaweedfs-filer-0 -- sh -c 'echo "s3.bucket.create -name loki" | weed shell'

# Restart loki-0. The first start populates index/ + delete_requests/ in the bucket;
# once populated, the compactor's GetObject no longer 404s and loki-0 goes 2/2 Ready.
kubectl delete pod loki-0 -n monitoring
```
Note: the `velero` bucket is likewise absent in SeaweedFS (only `kitaru-artifacts` + `loki` exist as of this fix) — velero backups will fail until it's created the same way.

### Duplicate Grafana (two Helm releases)

**Symptom:** Grafana deployed twice — one in `monitoring` (Helm release `grafana`, has the `grafana.local` Contour ingress, matches `stack.yaml`) and a stray one in its own `grafana` namespace (Helm release `grafana`, revision 1, **no ingress**).

**Fix (keep monitoring/grafana, remove the stray):**
```bash
helm uninstall grafana -n grafana        # removes the stray release
kubectl delete namespace grafana         # namespace was otherwise empty (no leftover PVCs)
```
The keeper (`monitoring/grafana`, with the ingress) is untouched.

### Velero backups silently failing — no BackupStorageLocation

**Symptom:**
- The daily backup schedule (`velero-daily-backup`, `0 2 * * *`) shows a recent `lastBackup` time, but **no backups ever succeed**.
- `kubectl get backups.velero.io -n velero` shows a large pile of backups all in `FailedValidation` (136 of them as of 2026-07-01, going back months).
- Velero pod logs spam: `error getting backup storage location: BackupStorageLocation.velero.io "default" not found`.

**Root cause (2026-07-01):**
Two independent gaps meant velero had produced **zero successful backups in 136 days**:
1. The `BackupStorageLocation` named `default` (which `--default-backup-storage-location=default` expects) **did not exist**. Every scheduled backup failed validation instantly.
2. The SeaweedFS `velero` bucket also didn't exist (only `kitaru-artifacts` + `loki` did).

Note: `kubectl get backup ...` resolves to the **Longhorn** `backups` CRD, not velero's — always use `kubectl get backups.velero.io` for velero backups.

**Fix:**
```bash
export KUBECONFIG=~/.foundry/kubeconfig; kubectl config use-context default

# 1. Create the velero bucket in SeaweedFS
kubectl exec -n seaweedfs seaweedfs-filer-0 -- sh -c 'echo "s3.bucket.create -name velero" | weed shell'

# 2. Create the default BackupStorageLocation (creds come from the existing
#    'velero' secret's 'cloud' key; endpoint is the in-cluster SeaweedFS S3 svc)
kubectl apply -f - <<'EOF'
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: default
  namespace: velero
spec:
  provider: aws
  objectStorage:
    bucket: velero
  credential:
    name: velero
    key: cloud
  config:
    region: us-east-1
    s3ForcePathStyle: "true"
    s3Url: http://seaweedfs-s3.seaweedfs.svc.cluster.local:8333
  default: true
EOF

# 3. Verify it validates + a test backup completes
kubectl get backupstoragelocation default -n velero -o jsonpath='{.status.phase}{"\n"}'  # -> Available
kubectl apply -f - <<'EOF'
apiVersion: velero.io/v1
kind: Backup
metadata: {name: test-backup-bsl-check, namespace: velero}
spec: {includedNamespaces: [velero], storageLocation: default, ttl: 24h0m0s}
EOF
kubectl get backups.velero.io test-backup-bsl-check -n velero -o jsonpath='{.status.phase}{"\n"}'  # -> Completed

# 4. Clean up the pile of old FailedValidation backups
kubectl delete backups.velero.io -n velero \
  $(kubectl get backups.velero.io -n velero -o jsonpath='{range .items[?(@.status.phase=="FailedValidation")]}{.metadata.name} {end}')
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
