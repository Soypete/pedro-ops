#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE="${OBSERVABILITY_RELEASE:-pedro-observability}"
NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"

for binary in kubectl helm; do
  command -v "$binary" >/dev/null || { echo "ERROR: $binary is required" >&2; exit 1; }
done
kubectl get nodes >/dev/null
kubectl -n "$NAMESPACE" get secret alertmanager-discord >/dev/null || {
  echo "ERROR: $NAMESPACE/alertmanager-discord is missing" >&2
  echo "Run scripts/sync-discord-alert-secret.sh first." >&2
  exit 1
}

helm upgrade --install "$RELEASE" "$REPO_ROOT/helm/observability" \
  --namespace "$NAMESPACE" --create-namespace --wait --timeout 5m
kubectl apply -f "$REPO_ROOT/k8s/openwebui/postgres.yaml"

echo "Waiting for Prometheus discovery..."
sleep 35
kubectl get servicemonitor,podmonitor,scrapeconfig,probe,prometheusrule,alertmanagerconfig -A \
  -l app.kubernetes.io/part-of=pedro-observability
