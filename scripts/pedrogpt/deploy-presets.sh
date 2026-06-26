#!/bin/bash

# Deploy the pedrogpt llama-server config and restart the service.
#
# pedrogpt runs a single dedicated Qwen3.6-27B MTP model launched by
# /opt/llama.cpp/run-server.sh from /etc/llama-server.env (see setup-llama-cpp.sh).
# This script pushes a local env file to the box and restarts llama-server.
#
# Router/--models-preset mode is retired; the reference INI in presets/ is kept only
# as a rollback artifact and is NOT deployed by this script.
#
# Prerequisites:
#   - SSH access to pedrogpt via Tailscale (ssh pedrogpt)
#   - llama-server systemd service installed (setup-llama-cpp.sh)
#
# Usage:
#   ./deploy-presets.sh --env path/to/llama-server.env   # push env + restart
#   ./deploy-presets.sh --restart                         # restart only (config already on box)
#   ./deploy-presets.sh --host pedrogpt ...               # override target host

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_HOST="pedrogpt"
REMOTE_ENV_FILE="/etc/llama-server.env"
SERVICE_NAME="llama-server"

ENV_FILE=""
RESTART_ONLY=false

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)     ENV_FILE="$2"; shift 2 ;;
    --restart) RESTART_ONLY=true; shift ;;
    --host)    REMOTE_HOST="$2"; shift 2 ;;
    -h|--help) head -20 "$0" | tail -17; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "=== Deploying llama-server config to $REMOTE_HOST ==="
echo ""

# ---------------------------------------------------------------------------
# Push env file (skipped with --restart)
# ---------------------------------------------------------------------------
if [[ "$RESTART_ONLY" == "false" ]]; then
  if [[ -z "$ENV_FILE" ]]; then
    echo "ERROR: provide --env <file> (the local llama-server.env to deploy) or use --restart."
    echo "       The env file holds MODEL, MODEL_ALIAS, SPEC_TYPE, N_CTX, etc. — keep secrets out of git."
    exit 1
  fi
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: env file not found: $ENV_FILE"
    exit 1
  fi

  echo "--- Copying $ENV_FILE -> $REMOTE_HOST:$REMOTE_ENV_FILE ---"
  scp "$ENV_FILE" "$REMOTE_HOST:/tmp/llama-server.env"
  ssh -t "$REMOTE_HOST" "sudo mv /tmp/llama-server.env $REMOTE_ENV_FILE && sudo chmod 600 $REMOTE_ENV_FILE"
  echo "  Deployed."
  echo ""
fi

# ---------------------------------------------------------------------------
# Restart and health-check
# ---------------------------------------------------------------------------
echo "--- Restarting $SERVICE_NAME ---"
ssh -t "$REMOTE_HOST" "sudo systemctl daemon-reload && sudo systemctl restart $SERVICE_NAME"
sleep 3

if ssh -t "$REMOTE_HOST" "sudo systemctl is-active --quiet $SERVICE_NAME"; then
  echo ""
  echo "=== $SERVICE_NAME active on $REMOTE_HOST ==="
  echo "Health:  curl http://$REMOTE_HOST:8080/health"
  echo "Models:  curl http://$REMOTE_HOST:8080/v1/models | jq '.data[].id'   # -> qwen3.6-27b-mtp"
  echo "Logs:    ssh $REMOTE_HOST sudo journalctl -u $SERVICE_NAME -f"
else
  echo "ERROR: $SERVICE_NAME failed to start"
  ssh -t "$REMOTE_HOST" "sudo journalctl -u $SERVICE_NAME -n 30"
  exit 1
fi

echo ""
echo "=== Done ==="
