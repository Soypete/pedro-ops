#!/bin/bash

# Deploy llama.cpp model presets to pedrogpt and restart the service.
#
# Copies preset INI files to pedrogpt via SCP (over Tailscale) and optionally
# restarts llama-server with the specified preset.
#
# Prerequisites:
#   - SSH access to pedrogpt via Tailscale (ssh pedrogpt)
#   - llama-server systemd service installed (setup-llama-cpp.sh)
#
# Usage:
#   ./deploy-presets.sh                    # Deploy all presets, no restart
#   ./deploy-presets.sh --preset text      # Deploy + activate text preset
#   ./deploy-presets.sh --preset code      # Deploy + activate code preset
#   ./deploy-presets.sh --preset vision    # Deploy + activate vision preset
#   ./deploy-presets.sh --preset all       # Deploy + activate router (all models)
#   ./deploy-presets.sh --taildrop         # Use Taildrop instead of SCP

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRESETS_DIR="$SCRIPT_DIR/presets"
REMOTE_HOST="pedrogpt"
REMOTE_PRESETS_DIR="/opt/llama.cpp/presets"
REMOTE_ENV_FILE="/etc/llama-server.env"
SERVICE_NAME="llama-server"

PRESET=""
USE_TAILDROP=false

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --preset)
      PRESET="$2"
      shift 2
      ;;
    --taildrop)
      USE_TAILDROP=true
      shift
      ;;
    --host)
      REMOTE_HOST="$2"
      shift 2
      ;;
    -h|--help)
      head -17 "$0" | tail -14
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Validate preset name
if [[ -n "$PRESET" ]]; then
  case "$PRESET" in
    text|code|vision|tts|all) ;;
    *)
      echo "ERROR: Unknown preset '$PRESET'"
      echo "Valid presets: text, code, vision, tts, all"
      exit 1
      ;;
  esac
fi

# Map preset name to INI file
preset_file() {
  case "$1" in
    text)   echo "text.ini" ;;
    code)   echo "code.ini" ;;
    vision) echo "vision.ini" ;;
    tts)    echo "tts.ini" ;;
    all)    echo "all-models.ini" ;;
  esac
}

echo "=== Deploying llama.cpp presets to $REMOTE_HOST ==="
echo ""

# ---------------------------------------------------------------------------
# Copy preset files
# ---------------------------------------------------------------------------
if [[ "$USE_TAILDROP" == "true" ]]; then
  echo "--- Sending presets via Taildrop ---"
  for f in "$PRESETS_DIR"/*.ini; do
    echo "  Sending $(basename "$f")"
    tailscale file cp "$f" "$REMOTE_HOST:"
  done
  echo ""
  echo "Files sent via Taildrop. On pedrogpt, accept and move them:"
  echo "  sudo mkdir -p $REMOTE_PRESETS_DIR"
  echo "  sudo mv ~/Taildrop/*.ini $REMOTE_PRESETS_DIR/"
  echo ""

  if [[ -n "$PRESET" ]]; then
    echo "Then restart the service with:"
    echo "  sudo systemctl restart $SERVICE_NAME"
    echo ""
    echo "(Cannot auto-restart via Taildrop — use SCP mode for full automation)"
  fi
else
  echo "--- Copying presets via SCP ---"
  ssh -t "$REMOTE_HOST" "sudo mkdir -p $REMOTE_PRESETS_DIR"
  scp "$PRESETS_DIR"/*.ini "$REMOTE_HOST:/tmp/"
  ssh -t "$REMOTE_HOST" "sudo mv /tmp/*.ini $REMOTE_PRESETS_DIR/ && sudo chmod 644 $REMOTE_PRESETS_DIR/*.ini"
  echo "  Presets deployed to $REMOTE_HOST:$REMOTE_PRESETS_DIR/"
  echo ""

  # -------------------------------------------------------------------------
  # Restart service with preset (SCP mode only)
  # -------------------------------------------------------------------------
  if [[ -n "$PRESET" ]]; then
    INI_FILE="$(preset_file "$PRESET")"
    REMOTE_INI="$REMOTE_PRESETS_DIR/$INI_FILE"

    echo "--- Activating preset: $PRESET ($INI_FILE) ---"

    # Build extra flags for specific presets
    EXTRA_FLAGS=""
    if [[ "$PRESET" == "code" || "$PRESET" == "all" ]]; then
      # MoE expert offload: keep attention on GPU, experts in 64GB RAM
      EXTRA_FLAGS='    -ot ".ffn_.*_exps.=CPU" \\\n    --flash-attn \\'
    fi

    PRESET_PORT="\${PORT}"
    if [[ "$PRESET" == "tts" ]]; then
      PRESET_PORT="8001"
    fi

    # Update the systemd override to use --models-preset
    ssh -t "$REMOTE_HOST" "sudo mkdir -p /etc/systemd/system/${SERVICE_NAME}.service.d"
    ssh "$REMOTE_HOST" "sudo tee /etc/systemd/system/${SERVICE_NAME}.service.d/preset.conf > /dev/null" <<EOF
[Service]
ExecStart=
ExecStart=/opt/llama.cpp/build/bin/llama-server \\
    --host 0.0.0.0 \\
    --port $PRESET_PORT \\
    --models-preset $REMOTE_INI \\
    --models-max 1 \\
    --parallel \${N_PARALLEL} \\
    --jinja \\
    --no-webui \\
    --metrics$(if [[ -n "$EXTRA_FLAGS" ]]; then printf " \\\\\n$EXTRA_FLAGS"; fi)
EOF

    ssh -t "$REMOTE_HOST" "sudo systemctl daemon-reload && sudo systemctl restart $SERVICE_NAME"
    sleep 3

    # Check health
    if ssh -t "$REMOTE_HOST" "sudo systemctl is-active --quiet $SERVICE_NAME"; then
      echo ""
      echo "=== Preset '$PRESET' active on $REMOTE_HOST ==="
      echo "Health:  curl http://$REMOTE_HOST:8080/health"
      echo "Models:  curl http://$REMOTE_HOST:8080/v1/models"
      echo "Logs:    ssh $REMOTE_HOST sudo journalctl -u $SERVICE_NAME -f"
    else
      echo "ERROR: $SERVICE_NAME failed to start"
      ssh -t "$REMOTE_HOST" "sudo journalctl -u $SERVICE_NAME -n 30"
      exit 1
    fi
  else
    echo "Presets deployed. Use --preset <name> to activate one."
    echo "Available: text, code, vision, tts, all"
  fi
fi

echo ""
echo "=== Done ==="
