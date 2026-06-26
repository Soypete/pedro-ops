#!/bin/bash

# Switch the active model on pedrogpt (single-model mode).
#
# pedrogpt runs ONE tuned model launched by /opt/llama.cpp/run-server.sh from
# /etc/llama-server.env. This script updates MODEL (the local GGUF path) and
# MODEL_ALIAS (the API id) in that env file, then restarts llama-server.
#
# Run this ON pedrogpt (it edits /etc/llama-server.env directly).
#
# Current model: Qwen3.6-27B MTP (qwen3.6-27b-mtp) — has a built-in MTP draft head,
# enabled via SPEC_TYPE=draft-mtp in the env file. No separate draft model needed.
#
# Usage:
#   ./switch-model.sh <gguf-path> <api-alias>
#   ./switch-model.sh download <hf-repo> <include-glob> <local-dir>   # fetch a new GGUF
#
# Examples:
#   ./switch-model.sh /opt/models/qwen3.6-27b-mtp/Qwen3.6-27B-MTP-UD-Q4_K_XL.gguf qwen3.6-27b-mtp
#   ./switch-model.sh download unsloth/Qwen3.6-27B-MTP-GGUF "*UD-Q4_K_XL*" /opt/models/qwen3.6-27b-mtp

set -euo pipefail

ENV_FILE="/etc/llama-server.env"
SUBCOMMAND="${1:-}"

# ---------------------------------------------------------------------------
# download: fetch a GGUF into /opt/models
# ---------------------------------------------------------------------------
if [[ "$SUBCOMMAND" == "download" ]]; then
  HF_REPO="${2:-}"; INCLUDE="${3:-}"; LOCAL_DIR="${4:-}"
  if [[ -z "$HF_REPO" || -z "$INCLUDE" || -z "$LOCAL_DIR" ]]; then
    echo "Usage: $0 download <hf-repo> <include-glob> <local-dir>"
    exit 1
  fi
  echo "=== Downloading $HF_REPO ($INCLUDE) -> $LOCAL_DIR ==="
  hf download "$HF_REPO" --include "$INCLUDE" --local-dir "$LOCAL_DIR"
  echo "Done. Activate it with: $0 <gguf-path> <api-alias>"
  exit 0
fi

# ---------------------------------------------------------------------------
# switch: update MODEL/MODEL_ALIAS and restart
# ---------------------------------------------------------------------------
MODEL_PATH="${1:-}"
MODEL_ALIAS="${2:-}"

if [[ -z "$MODEL_PATH" || -z "$MODEL_ALIAS" ]]; then
  echo "Usage: $0 <gguf-path> <api-alias>"
  echo "       $0 download <hf-repo> <include-glob> <local-dir>"
  echo ""
  echo "Example:"
  echo "  $0 /opt/models/qwen3.6-27b-mtp/Qwen3.6-27B-MTP-UD-Q4_K_XL.gguf qwen3.6-27b-mtp"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run setup-llama-cpp.sh first."
  exit 1
fi

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "WARNING: $MODEL_PATH not found on disk. Download it first with: $0 download ..."
fi

echo "=== Switching model ==="
echo "MODEL:       $MODEL_PATH"
echo "MODEL_ALIAS: $MODEL_ALIAS"
echo ""

# If this model has no MTP head, disable MTP to avoid a startup error.
if [[ "$MODEL_PATH" != *MTP* && "$MODEL_PATH" != *mtp* ]]; then
  echo "NOTE: '$MODEL_PATH' doesn't look like an MTP GGUF — clearing SPEC_TYPE so the"
  echo "      server doesn't try to enable MTP on a model without a draft head."
  sudo sed -i "s|^SPEC_TYPE=.*|SPEC_TYPE=|" "$ENV_FILE"
fi

sudo sed -i "s|^MODEL=.*|MODEL=$MODEL_PATH|" "$ENV_FILE"
sudo sed -i "s|^MODEL_ALIAS=.*|MODEL_ALIAS=$MODEL_ALIAS|" "$ENV_FILE"

echo "Updated $ENV_FILE. Restarting llama-server..."
sudo systemctl restart llama-server
sleep 5

if sudo systemctl is-active --quiet llama-server; then
  echo ""
  echo "=== Active model: $MODEL_ALIAS ==="
  echo "Health:  curl http://localhost:8000/health"
  echo "Models:  curl http://localhost:8000/v1/models | jq '.data[].id'"
  echo "Logs:    sudo journalctl -u llama-server -f"
else
  echo "ERROR: llama-server failed to start"
  sudo journalctl -u llama-server -n 30
  exit 1
fi
