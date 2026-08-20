#!/bin/bash

# Manage the models served by llama-server on pedrogpt (ROUTER mode).
#
# Router mode changes what "switching" means. There is no longer an active model to
# swap: both models are always registered and callers pick one per request via the
# "model" field in /v1/chat/completions. This script only controls which is RESIDENT
# in VRAM.
#
# Because --models-max 1 (two 27B Q4 models do not fit in 32GB together), loading one
# model evicts the other. Each swap unloads ~18 GB and reads ~18 GB from disk, so the
# first request after a switch stalls noticeably.
#
# You usually do NOT need this script: with --models-autoload, naming a model in a
# request loads it automatically. Use this to pre-warm a model before a benchmark, or
# to free VRAM.
#
# Models are defined in presets/router.ini and deployed by deploy-presets.sh. To add or
# retune a model, edit that INI and redeploy — not this script.
#
# Runs from anywhere with access to the server (defaults to localhost; use --host).
#
# Usage:
#   ./switch-model.sh list                        # models + load status
#   ./switch-model.sh load   <model-id>           # load into VRAM (evicts the other)
#   ./switch-model.sh unload <model-id>           # free VRAM
#   ./switch-model.sh download <hf-repo> <include-glob> <local-dir>
#   ./switch-model.sh --host pedrogpt list
#
# Examples:
#   ./switch-model.sh load qwen3.8-27b
#   ./switch-model.sh download unsloth/Qwen3.8-27B-GGUF "Qwen3.8-27B-UD-Q4_K_XL.gguf" /opt/models/qwen3.8-27b

set -euo pipefail

HOST="localhost"
PORT="8000"

# Allow --host/--port before the subcommand.
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    -h|--help) sed -n "3,33p" "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

BASE="http://${HOST}:${PORT}"
SUBCOMMAND="${1:-}"

usage() {
  echo "Usage: $0 [--host H] [--port P] list"
  echo "       $0 [--host H] [--port P] load   <model-id>"
  echo "       $0 [--host H] [--port P] unload <model-id>"
  echo "       $0 download <hf-repo> <include-glob> <local-dir>"
}

# ---------------------------------------------------------------------------
# download: fetch a GGUF into /opt/models (does NOT register it — add a section
# to presets/router.ini and redeploy for the router to serve it)
# ---------------------------------------------------------------------------
if [[ "$SUBCOMMAND" == "download" ]]; then
  HF_REPO="${2:-}"; INCLUDE="${3:-}"; LOCAL_DIR="${4:-}"
  if [[ -z "$HF_REPO" || -z "$INCLUDE" || -z "$LOCAL_DIR" ]]; then
    echo "Usage: $0 download <hf-repo> <include-glob> <local-dir>"
    exit 1
  fi
  echo "=== Downloading $HF_REPO ($INCLUDE) -> $LOCAL_DIR ==="
  hf download "$HF_REPO" --include "$INCLUDE" --local-dir "$LOCAL_DIR"
  echo ""
  echo "Downloaded. To serve it:"
  echo "  1. add a section to presets/router.ini with model = $LOCAL_DIR/<file>.gguf"
  echo "  2. ./deploy-presets.sh --env <your-env-file>"
  exit 0
fi

# ---------------------------------------------------------------------------
# list / load / unload
# ---------------------------------------------------------------------------
case "$SUBCOMMAND" in
  list)
    echo "=== Models on $BASE ==="
    if ! curl -sf --max-time 10 "$BASE/v1/models" > /tmp/.models.$$ 2>/dev/null; then
      echo "ERROR: cannot reach $BASE/v1/models"
      rm -f /tmp/.models.$$
      exit 1
    fi
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
rows = d.get("data", [])
if not rows:
    print("  (no models registered)")
for m in rows:
    status = (m.get("status") or {}).get("value", "unknown")
    print("  %-24s %s" % (m.get("id", "?"), status))
' /tmp/.models.$$
    rm -f /tmp/.models.$$
    ;;

  load|unload)
    MODEL_ID="${2:-}"
    if [[ -z "$MODEL_ID" ]]; then
      echo "ERROR: $SUBCOMMAND requires a model id."
      echo ""
      usage
      exit 1
    fi
    echo "=== ${SUBCOMMAND}ing $MODEL_ID ==="
    if [[ "$SUBCOMMAND" == "load" ]]; then
      echo "(with --models-max 1 this evicts the other model; expect ~18 GB of I/O)"
    fi
    if curl -sf --max-time 600 -X POST "$BASE/models/$SUBCOMMAND" \
         -H 'Content-Type: application/json' \
         -d "{\"model\":\"$MODEL_ID\"}" > /dev/null; then
      echo "OK."
      echo ""
      "$0" --host "$HOST" --port "$PORT" list
    else
      echo "ERROR: $SUBCOMMAND failed for '$MODEL_ID'."
      echo "       Check the id is a section name in presets/router.ini:"
      echo "         $0 --host $HOST list"
      exit 1
    fi
    ;;

  ""|help|-h|--help)
    usage
    exit 0
    ;;

  *)
    echo "ERROR: unknown subcommand '$SUBCOMMAND'"
    echo ""
    usage
    exit 1
    ;;
esac
