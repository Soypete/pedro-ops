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

## Security Note

Currently, Zot is running **without authentication** for internal cluster use. Images are accessible from:
- Control plane
- Worker nodes
- Any pod in the cluster

For production, consider enabling:
- Authentication (basic auth or OAuth)
- TLS/HTTPS
- Access controls
