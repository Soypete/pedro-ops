#!/bin/bash
# llama-server launcher — reads /etc/llama-server.env and starts llama-server in
# ROUTER mode. Called by the llama-server systemd service.
#
# Router mode is selected by the ABSENCE of -m/--model: this process loads no model and
# does not touch the GPU. Models are declared in $MODELS_PRESET, and each is spawned as
# its own child llama-server process on demand, inheriting this process's environment.
# Per-model tuning therefore lives in the preset INI, not here.
#
# Source of truth: this file is deployed to /opt/llama.cpp/run-server.sh by
# deploy-presets.sh (and installed by setup-llama-cpp.sh). Edit it here, then deploy.
set -euo pipefail

ENV_FILE="/etc/llama-server.env"
# shellcheck source=/etc/llama-server.env
source "$ENV_FILE"

export HF_HOME="${HF_HOME:-/opt/models/cache}"
# Explicit: LLAMA_CACHE outranks HF_HOME for llama.cpp's own -hf pulls
# (common/hf-cache.cpp). Stating it means the download path never depends on the
# export ordering above.
export LLAMA_CACHE="${LLAMA_CACHE:-/opt/models/cache/llama.cpp}"
export HUGGING_FACE_HUB_TOKEN="${HF_TOKEN:-}"

MODELS_PRESET="${MODELS_PRESET:-/etc/llama-server-models.ini}"
if [[ ! -f "$MODELS_PRESET" ]]; then
  echo "ERROR: models preset not found: $MODELS_PRESET" >&2
  echo "       Deploy it with: ./deploy-presets.sh --env <env-file>" >&2
  exit 1
fi

EXTRA_ARGS=()

# Autoload a model when a request names one that is not resident.
# With MODELS_MAX=1 this is what makes model switching work at all.
if [[ "${MODELS_AUTOLOAD:-1}" == "1" ]]; then
  EXTRA_ARGS+=(--models-autoload)
else
  EXTRA_ARGS+=(--no-models-autoload)
fi

# NOTE: no -m/--model here — that is what selects router mode.
#
# Do NOT add per-model tuning flags below. CLI args outrank preset sections and would be
# applied to EVERY model: --spec-type in particular would crash the non-MTP model.
# Add such flags to the model's section in $MODELS_PRESET instead.
exec /opt/llama.cpp/build/bin/llama-server \
    --host 0.0.0.0 \
    --port "${PORT:-8000}" \
    --models-preset "$MODELS_PRESET" \
    --models-max "${MODELS_MAX:-1}" \
    "${EXTRA_ARGS[@]}"
