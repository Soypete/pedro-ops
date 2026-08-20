#!/usr/bin/env bash
# Run on pedrogpt. Publishes host and GPU metrics on the Tailscale address only.
set -euo pipefail

TS_IP="${PEDROGPT_TS_IP:-100.121.229.114}"
NODE_IMAGE="${NODE_EXPORTER_IMAGE:-quay.io/prometheus/node-exporter:v1.8.2}"
DCGM_IMAGE="${DCGM_EXPORTER_IMAGE:-nvcr.io/nvidia/k8s/dcgm-exporter:3.3.9-3.6.1-ubuntu22.04}"

command -v docker >/dev/null || { echo "ERROR: docker is required" >&2; exit 1; }
ip -4 addr show tailscale0 | grep -Fq "$TS_IP" || {
  echo "ERROR: $TS_IP is not assigned to tailscale0" >&2
  exit 1
}

docker pull "$NODE_IMAGE"
docker pull "$DCGM_IMAGE"
docker rm -f pedrogpt-node-exporter pedrogpt-dcgm-exporter 2>/dev/null || true
docker run -d --name pedrogpt-node-exporter --restart unless-stopped \
  --network host --pid host \
  -v /:/host:ro \
  "$NODE_IMAGE" --path.rootfs=/host --web.listen-address="$TS_IP:9100"

if [ ! -x /usr/bin/nvidia-cuda-mps-control ]; then
  echo "ERROR: /usr/bin/nvidia-cuda-mps-control is missing; DCGM cannot start with this NVIDIA runtime." >&2
  echo "Install the driver-matched nvidia-compute-utils package, then rerun this script." >&2
  exit 1
fi
docker run -d --name pedrogpt-dcgm-exporter --restart unless-stopped \
  --gpus all --cap-add SYS_ADMIN \
  -p "$TS_IP:9400:9400" "$DCGM_IMAGE"

curl --fail --silent "http://$TS_IP:9100/metrics" >/dev/null
curl --fail --silent "http://$TS_IP:9400/metrics" >/dev/null
echo "pedrogpt node and GPU exporters are healthy on Tailscale"
