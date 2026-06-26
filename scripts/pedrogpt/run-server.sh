#!/bin/bash
# llama-server launcher — reads /etc/llama-server.env and starts the tuned
# Qwen3.6-27B MTP single-model server. Called by the llama-server systemd service.
#
# Source of truth: this file is deployed to /opt/llama.cpp/run-server.sh by
# deploy-presets.sh (and installed by setup-llama-cpp.sh). Edit it here, then deploy.
set -euo pipefail

ENV_FILE="/etc/llama-server.env"
# shellcheck source=/etc/llama-server.env
source "$ENV_FILE"

export HF_HOME="${HF_HOME:-/opt/models/cache}"
export HUGGING_FACE_HUB_TOKEN="${HF_TOKEN:-}"

EXTRA_ARGS=()

# MTP self-speculative decoding (no separate draft model — the head is in the GGUF).
if [[ -n "${SPEC_TYPE:-}" ]]; then
  EXTRA_ARGS+=(--spec-type "${SPEC_TYPE}" --spec-draft-n-max "${SPEC_DRAFT_N:-3}")
fi

# Quantized KV cache (requires flash-attn; K and V must match).
if [[ -n "${CACHE_TYPE_K:-}" ]]; then
  EXTRA_ARGS+=(--cache-type-k "${CACHE_TYPE_K}" --cache-type-v "${CACHE_TYPE_V:-$CACHE_TYPE_K}")
fi

# Embeddings endpoint — opt-in only. Enabling it builds an embeddings output graph
# that is incompatible with some models / the MTP spec-decoding graph and will
# crash the server on load (GGML_ASSERT "missing result_norm/result_embd tensor").
# Leave EMBEDDINGS unset for a chat-completions-only server.
if [[ "${EMBEDDINGS:-}" == "1" ]]; then
  EXTRA_ARGS+=(--embeddings --pooling "${POOLING:-mean}")
fi

exec /opt/llama.cpp/build/bin/llama-server \
    --host 0.0.0.0 \
    --port "${PORT:-8080}" \
    -m "${MODEL}" \
    --alias "${MODEL_ALIAS:-qwen3.6-27b-mtp}" \
    --ctx-size "${N_CTX:-65536}" \
    --n-gpu-layers "${N_GPU_LAYERS:-99}" \
    --parallel "${N_PARALLEL:-1}" \
    --batch-size "${BATCH:-2048}" \
    --ubatch-size "${UBATCH:-1024}" \
    --flash-attn on \
    --mlock \
    --jinja \
    --no-webui \
    --metrics \
    --temp "${TEMP:-0.7}" \
    --top-k "${TOP_K:-20}" \
    --top-p "${TOP_P:-0.8}" \
    --presence-penalty "${PRESENCE_PENALTY:-1.5}" \
    --min-p "${MIN_P:-0.0}" \
    --chat-template-kwargs '{"enable_thinking":false}' \
    "${EXTRA_ARGS[@]}"
