#!/bin/bash

# Deploy the pedrogpt llama-server config and restart the service.
#
# pedrogpt runs llama-server in ROUTER mode (started with no -m/--model), serving two
# models that swap in and out of VRAM on demand. This script:
#   1. SCPs run-server.sh (the launcher wrapper) to the box
#   2. SCPs presets/router.ini to /etc/llama-server-models.ini (per-model tuning)
#   3. SCPs your env file to /etc/llama-server.env (holds secrets — keep out of git)
#   4. ensures the systemd unit's ExecStart points at run-server.sh
#   5. daemon-reload + restart, then health-checks
#
# Per-model flags live in router.ini, NOT on the llama-server command line: CLI args
# outrank preset sections and would hit every model (--spec-type would crash the
# non-MTP model). See presets/README.md for the full flag mapping.
#
# NOTE: this uses `ssh -tt` to force a PTY so sudo can prompt for your password.
# Run it from a real interactive terminal (not a non-interactive wrapper/CI), or it
# will fail with "a terminal is required to read the password". To make it fully
# non-interactive, add a passwordless-sudo rule on pedrogpt for the install/systemctl/
# tee/rm commands below (/etc/sudoers.d/llama-deploy) and switch `ssh -tt` to `ssh`.
#
# Prerequisites:
#   - SSH access to pedrogpt via Tailscale (ssh pedrogpt), from an interactive terminal
#   - llama-server already built at /opt/llama.cpp/build/bin/llama-server
#
# Usage:
#   ./deploy-presets.sh --env path/to/llama-server.env   # full deploy (wrapper + env + unit)
#   ./deploy-presets.sh --restart                         # restart only
#   ./deploy-presets.sh --host pedrogpt ...               # override target host

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_HOST="pedrogpt"
REMOTE_ENV_FILE="/etc/llama-server.env"
REMOTE_PRESET_FILE="/etc/llama-server-models.ini"
REMOTE_WRAPPER="/opt/llama.cpp/run-server.sh"
SERVICE_FILE="/etc/systemd/system/llama-server.service"
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
    -h|--help) sed -n "3,30p" "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "=== Deploying llama-server config to $REMOTE_HOST ==="
echo ""

# ---------------------------------------------------------------------------
# Full deploy: wrapper + env + unit (skipped with --restart)
# ---------------------------------------------------------------------------
if [[ "$RESTART_ONLY" == "false" ]]; then
  if [[ -z "$ENV_FILE" ]]; then
    echo "ERROR: provide --env <file> (the local llama-server.env to deploy) or use --restart."
    echo "       The env file holds MODELS_PRESET, MODELS_MAX, PORT, HF_TOKEN, etc."
    echo "       Per-model tuning lives in presets/router.ini, not the env file."
    exit 1
  fi
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: env file not found: $ENV_FILE"
    exit 1
  fi

  if [[ ! -f "$SCRIPT_DIR/presets/router.ini" ]]; then
    echo "ERROR: preset not found: $SCRIPT_DIR/presets/router.ini"
    exit 1
  fi

  echo "--- Copying launcher wrapper -> $REMOTE_HOST:$REMOTE_WRAPPER ---"
  scp "$SCRIPT_DIR/run-server.sh" "$REMOTE_HOST:/tmp/run-server.sh"

  echo "--- Copying router preset -> $REMOTE_HOST:$REMOTE_PRESET_FILE ---"
  scp "$SCRIPT_DIR/presets/router.ini" "$REMOTE_HOST:/tmp/llama-server-models.ini"

  echo "--- Copying $ENV_FILE -> $REMOTE_HOST:$REMOTE_ENV_FILE ---"
  scp "$ENV_FILE" "$REMOTE_HOST:/tmp/llama-server.env"

  # Install wrapper + preset + env, and pin ExecStart to the wrapper.
  echo "--- Installing on $REMOTE_HOST (sudo — you'll be prompted for your password) ---"
  ssh -tt "$REMOTE_HOST" "sudo install -m 0755 /tmp/run-server.sh $REMOTE_WRAPPER \
    && sudo install -m 0600 /tmp/llama-server.env $REMOTE_ENV_FILE \
    && sudo install -m 0644 /tmp/llama-server-models.ini $REMOTE_PRESET_FILE \
    && printf '%s\n' \
        '[Unit]' \
        'Description=llama.cpp Server (router: qwen3.6-27b-mtp + qwen3.8-27b)' \
        'After=network-online.target' \
        'Wants=network-online.target' \
        '' \
        '[Service]' \
        'Type=simple' \
        'ExecStart=/opt/llama.cpp/run-server.sh' \
        'Restart=on-failure' \
        'RestartSec=10' \
        'TimeoutStopSec=120' \
        'SyslogIdentifier=llama-server' \
        'SupplementaryGroups=render video' \
        '' \
        '[Install]' \
        'WantedBy=multi-user.target' \
      | sudo tee $SERVICE_FILE >/dev/null \
    && rm -f /tmp/run-server.sh /tmp/llama-server.env /tmp/llama-server-models.ini"
  echo "  Wrapper, preset, env, and unit installed."
  echo ""
fi

# ---------------------------------------------------------------------------
# Restart and health-check
# ---------------------------------------------------------------------------
echo "--- Restarting $SERVICE_NAME ---"
ssh -tt "$REMOTE_HOST" "sudo systemctl daemon-reload && sudo systemctl restart $SERVICE_NAME"
sleep 5

if ssh -tt "$REMOTE_HOST" "sudo systemctl is-active --quiet $SERVICE_NAME"; then
  echo ""
  echo "=== $SERVICE_NAME active on $REMOTE_HOST ==="
  echo "Health:  curl http://$REMOTE_HOST:8000/health"
  echo "Models:  curl http://$REMOTE_HOST:8000/v1/models | jq '.data[].id'   # -> qwen3.6-27b-mtp, qwen3.8-27b"
  echo "Metrics: curl '"'"'http://$REMOTE_HOST:8000/metrics?model=qwen3.6-27b-mtp&autoload=false'"'"'"
  echo "Logs:    ssh $REMOTE_HOST sudo journalctl -u $SERVICE_NAME -f"
else
  echo "ERROR: $SERVICE_NAME failed to start"
  ssh -tt "$REMOTE_HOST" "sudo journalctl -u $SERVICE_NAME -n 40"
  exit 1
fi

echo ""
echo "=== Done ==="
