#!/bin/bash

# Deploy the pedrogpt llama-server config and restart the service.
#
# pedrogpt runs a single dedicated Qwen3.6-27B MTP model launched by
# /opt/llama.cpp/run-server.sh from /etc/llama-server.env. This script:
#   1. SCPs run-server.sh (the launcher wrapper) to the box
#   2. SCPs your env file to /etc/llama-server.env (holds secrets — keep out of git)
#   3. removes any leftover router/--models-preset drop-in
#   4. installs the committed llama-server.service unit (ExecStart=run-server.sh)
#   5. daemon-reload + restart, then health-checks
#
# Router/--models-preset mode is retired; the INI in presets/ is a rollback artifact only.
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
#   ./deploy-presets.sh --taildrop --env <file>           # send files via Taildrop (manual install)
#   ./deploy-presets.sh --host pedrogpt ...               # override target host

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_HOST="pedrogpt"
REMOTE_ENV_FILE="/etc/llama-server.env"
REMOTE_WRAPPER="/opt/llama.cpp/run-server.sh"
SERVICE_FILE="/etc/systemd/system/llama-server.service"
SERVICE_NAME="llama-server"

ENV_FILE=""
RESTART_ONLY=false
USE_TAILDROP=false

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)      ENV_FILE="$2"; shift 2 ;;
    --restart)  RESTART_ONLY=true; shift ;;
    --taildrop) USE_TAILDROP=true; shift ;;
    --host)     REMOTE_HOST="$2"; shift 2 ;;
    -h|--help)  head -24 "$0" | tail -21; exit 0 ;;
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
    echo "       Start from the template: cp llama-server.env.example /tmp/llama-server.env,"
    echo "       paste your HF_TOKEN into it, then: $0 --env /tmp/llama-server.env"
    exit 1
  fi
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: env file not found: $ENV_FILE"
    exit 1
  fi

  # -------------------------------------------------------------------------
  # Taildrop mode: send the files, print manual install steps, and stop.
  # (Taildrop can't sudo-install or restart — use SCP mode for full automation.)
  # -------------------------------------------------------------------------
  if [[ "$USE_TAILDROP" == "true" ]]; then
    echo "--- Sending files via Taildrop ---"
    tailscale file cp "$SCRIPT_DIR/run-server.sh" "$REMOTE_HOST:"
    tailscale file cp "$SCRIPT_DIR/llama-server.service" "$REMOTE_HOST:"
    tailscale file cp "$ENV_FILE" "$REMOTE_HOST:"
    echo ""
    echo "Files sent. On $REMOTE_HOST, accept them and run:"
    echo "  sudo install -m 0755 ~/Taildrop/run-server.sh $REMOTE_WRAPPER"
    echo "  sudo install -m 0600 ~/Taildrop/$(basename "$ENV_FILE") $REMOTE_ENV_FILE"
    echo "  sudo install -m 0644 ~/Taildrop/llama-server.service $SERVICE_FILE"
    echo "  sudo rm -f /etc/systemd/system/${SERVICE_NAME}.service.d/preset.conf"
    echo "  sudo systemctl daemon-reload && sudo systemctl restart $SERVICE_NAME"
    exit 0
  fi

  echo "--- Copying launcher wrapper -> $REMOTE_HOST:$REMOTE_WRAPPER ---"
  scp "$SCRIPT_DIR/run-server.sh" "$REMOTE_HOST:/tmp/run-server.sh"

  echo "--- Copying systemd unit -> $REMOTE_HOST:$SERVICE_FILE ---"
  scp "$SCRIPT_DIR/llama-server.service" "$REMOTE_HOST:/tmp/llama-server.service"

  echo "--- Copying $ENV_FILE -> $REMOTE_HOST:$REMOTE_ENV_FILE ---"
  scp "$ENV_FILE" "$REMOTE_HOST:/tmp/llama-server.env"

  # Install wrapper + env + committed unit, and retire the router drop-in.
  echo "--- Installing on $REMOTE_HOST (sudo — you'll be prompted for your password) ---"
  ssh -tt "$REMOTE_HOST" "sudo install -m 0755 /tmp/run-server.sh $REMOTE_WRAPPER \
    && sudo install -m 0600 /tmp/llama-server.env $REMOTE_ENV_FILE \
    && sudo install -m 0644 /tmp/llama-server.service $SERVICE_FILE \
    && sudo rm -f /etc/systemd/system/${SERVICE_NAME}.service.d/preset.conf \
    && sudo rmdir /etc/systemd/system/${SERVICE_NAME}.service.d 2>/dev/null || true \
    && rm -f /tmp/run-server.sh /tmp/llama-server.env /tmp/llama-server.service"
  echo "  Wrapper, env, and unit installed; router drop-in removed."
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
  echo "Models:  curl http://$REMOTE_HOST:8000/v1/models | jq '.data[].id'   # -> qwen3.6-27b-mtp"
  echo "Logs:    ssh $REMOTE_HOST sudo journalctl -u $SERVICE_NAME -f"
else
  echo "ERROR: $SERVICE_NAME failed to start"
  ssh -tt "$REMOTE_HOST" "sudo journalctl -u $SERVICE_NAME -n 40"
  exit 1
fi

echo ""
echo "=== Done ==="
