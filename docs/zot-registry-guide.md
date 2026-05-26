# Zot Registry Guide

Zot is our internal container registry running on the pedro-ops cluster. It's accessible at `100.81.89.62:5000`.

## Quick Reference

**Registry URL**: `http://100.81.89.62:5000`
**Location**: Control plane (100.81.89.62)
**Running as**: Docker container (`foundry-zot`)
**Storage**: `/var/lib/foundry-zot` on control plane

## Checking Images in Zot

### List All Repositories

```bash
curl -s http://100.81.89.62:5000/v2/_catalog | jq
```

**Example output**:
```json
{
  "repositories": [
    "eleduck/sqlmesh",
    "airbyte/server",
    "grafana/grafana",
    ...
  ]
}
```

### List Tags for a Repository

```bash
# Format: curl http://100.81.89.62:5000/v2/<repo-name>/tags/list
curl -s http://100.81.89.62:5000/v2/eleduck/sqlmesh/tags/list | jq
```

**Example output**:
```json
{
  "name": "eleduck/sqlmesh",
  "tags": ["latest", "v1.0.0"]
}
```

### Get Image Manifest (Details)

```bash
curl -s http://100.81.89.62:5000/v2/eleduck/sqlmesh/manifests/latest | jq
```

## Building and Pushing Images to Zot

### 1. Build Your Image

```bash
cd /path/to/your/project
docker build -t 100.81.89.62:5000/your-app:tag -f Dockerfile .
```

### 2. Push to Zot

Since Zot is running without authentication:

```bash
docker push 100.81.89.62:5000/your-app:tag
```

### Example: SQLMesh

```bash
cd /Users/miriahpeterson/Code/go-projects/eleduck-analytics-connector
docker build -t 100.81.89.62:5000/eleduck/sqlmesh:latest -f docker/sqlmesh/Dockerfile .
docker push 100.81.89.62:5000/eleduck/sqlmesh:latest
```

## Using Images from Zot in Kubernetes

### In Pod Spec

```yaml
spec:
  containers:
    - name: my-container
      image: 100.81.89.62:5000/eleduck/sqlmesh:latest
      imagePullPolicy: Always
```

### In Helm Values

```yaml
image:
  repository: 100.81.89.62:5000/eleduck/sqlmesh
  tag: latest
  pullPolicy: Always
```

**Note**: No imagePullSecrets needed since Zot is running without authentication.

## Troubleshooting

### Check if Zot is Running

```bash
ssh root@100.81.89.62 'docker ps | grep zot'
```

Expected output:
```
foundry-zot    ghcr.io/project-zot/zot:latest    Up    0.0.0.0:5000->5000/tcp
```

### Test Registry API

```bash
curl -s http://100.81.89.62:5000/v2/ && echo "✓ Zot is accessible"
```

### Check Zot Logs

```bash
ssh root@100.81.89.62 'docker logs foundry-zot --tail 50'
```

### Check Storage Usage

```bash
ssh root@100.81.89.62 'du -sh /var/lib/foundry-zot'
```

## Advanced: Delete an Image

Zot supports garbage collection. To delete an image:

1. Delete the manifest:
```bash
# Get the digest first
DIGEST=$(curl -I -s http://100.81.89.62:5000/v2/eleduck/sqlmesh/manifests/latest | grep Docker-Content-Digest | awk '{print $2}' | tr -d '\r')

# Delete using digest
curl -X DELETE http://100.81.89.62:5000/v2/eleduck/sqlmesh/manifests/$DIGEST
```

2. Run garbage collection (on control plane):
```bash
ssh root@100.81.89.62
docker exec foundry-zot zot-linux-amd64 gc /var/lib/zot
```

## Common Image Patterns

### Analytics Stack
- `100.81.89.62:5000/eleduck/sqlmesh:latest` - SQLMesh transformation
- `100.81.89.62:5000/eleduck/podcast-scraper:latest` - Podcast scraper

### System Images
- `100.81.89.62:5000/grafana/grafana:*` - Grafana
- `100.81.89.62:5000/grafana/loki:*` - Loki
- `100.81.89.62:5000/airbyte/*` - Airbyte components

## Configuration

Zot config is at `/etc/foundry-zot/config.json` on the control plane.

To view config:
```bash
ssh root@100.81.89.62 'cat /etc/foundry-zot/config.json' | jq
```

## K3s Node Configuration

To pull images from the local Zot registry (`100.81.89.62:5000`), K3s nodes need the registry configured as insecure.

### Apply to All Nodes

Copy the registries config to each node and restart K3s:

```bash
# On each node (blue1, blue2, refurb):
scp scripts/k8s/registries.yaml <node>:/tmp/registries.yaml
ssh <node> "sudo cp /tmp/registries.yaml /etc/rancher/k3s/registries.yaml"

# Restart K3s
ssh blue1 "sudo systemctl restart k3s"  # control plane
ssh blue2 "sudo systemctl restart k3s-agent"  # workers
ssh refurb "sudo systemctl restart k3s-agent"  # workers
```

Or via SSH with stdin:

```bash
ssh -o StrictHostKeyChecking=no blue1 "sudo tee /etc/rancher/k3s/registries.yaml" < scripts/k8s/registries.yaml
ssh blue1 "sudo systemctl restart k3s"
```

### Node Hostnames
- **blue1**: 100.81.89.62 / 192.168.1.128 (control plane)
- **blue2**: 100.70.90.12 / 192.168.1.11 (worker)
- **refurb**: 100.125.196.1 / 192.168.1.253 (worker)

## Troubleshooting

### ImagePullBackOff: "http: server gave HTTP response to HTTPS client"

The K3s nodes need the insecure registry configured. See [K3s Node Configuration](#k3s-node-configuration) above.

After applying `registries.yaml` to each node, restart K3s:
```bash
# Control plane
ssh root@100.81.89.62 "systemctl restart k3s"
# Workers
ssh root@100.70.90.12 "systemctl restart k3s-agent"
ssh root@100.125.196.1 "systemctl restart k3s-agent"
```

### Image Tag Not Found

If pods fail with "not found", check the correct image tag:
```bash
curl -s http://100.81.89.62:5000/v2/<repo-name>/tags/list | jq
```

Update deployment to use correct tag:
```bash
kubectl set image deployment/<name> <container>=100.81.89.62:5000/<repo>:latest -n <namespace>
```

### Container Command Errors

If container fails with "invalid choice" errors, the image may use different entrypoints. Check what's available:
```bash
podman run --rm 100.81.89.62:5000/<image> --help
podman run --rm 100.81.89.62:5000/<image> agent --help
```

Fix deployment command:
```bash
kubectl patch deployment/<name> -n <namespace> -p '{"spec":{"template":{"spec":{"containers":[{"name":"<container>","command":["python","-m","main","agent","--agent","social-poster"]}]}}}}'
```

### Missing Environment Variables

Pods may crash if required env vars are missing. Add them:
```bash
kubectl patch deployment/<name> -n <namespace> -p '{"spec":{"template":{"spec":{"containers":[{"name":"<container>","env":[{"name":"LLAMA_CPP_BASE_URL","value":"http://100.121.229.114:8080"}]}]}}}}'
```

### Database Connection Errors

If pods fail with "Tenant or user not found", the database credentials have changed. Update the secrets in the deployment.

## Security Note

Currently, Zot is running **without authentication** for internal cluster use. Images are accessible from:
- Control plane
- Worker nodes
- Any pod in the cluster

For production, consider enabling:
- Authentication (basic auth or OAuth)
- TLS/HTTPS
- Access controls
