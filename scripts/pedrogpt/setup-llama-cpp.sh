#!/bin/bash

# Setup llama.cpp on Ubuntu (pedrogpt) with CUDA support.
# Builds llama-server and installs it as a systemd service that
# exposes Prometheus metrics at :8000/metrics.
#
# Usage: ./setup-llama-cpp-ubuntu.sh [--rebuild]
#   --rebuild  Force a clean rebuild even if llama.cpp is already installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLAMA_DIR="/opt/llama.cpp"
MODEL_DIR="/opt/models"
ENV_FILE="/etc/llama-server.env"
SERVICE_FILE="/etc/systemd/system/llama-server.service"
PORT=8000

REBUILD=false
for arg in "$@"; do
  [[ "$arg" == "--rebuild" ]] && REBUILD=true
done

echo "=== llama.cpp Setup for pedrogpt ==="
echo "LLAMA_DIR:  $LLAMA_DIR"
echo "MODEL_DIR:  $MODEL_DIR"
echo "Port:       $PORT"
echo ""

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
echo "--- Installing build dependencies ---"
sudo apt-get update -qq
sudo apt-get install -y \
  build-essential cmake git curl wget unzip \
  libssl-dev libcurl4-openssl-dev \
  python3-pip

# 1Password CLI (used by switch-model.sh to fetch HF_TOKEN)
if ! command -v op &>/dev/null; then
  echo "--- Installing 1Password CLI ---"
  OP_VERSION="2.30.0"
  curl -sSfLo /tmp/op.zip \
    "https://cache.agilebits.com/dist/1P/op2/pkg/v${OP_VERSION}/op_linux_amd64_v${OP_VERSION}.zip"
  sudo unzip -o /tmp/op.zip -d /usr/local/bin op
  sudo chmod +x /usr/local/bin/op
  rm /tmp/op.zip
  echo "op CLI installed: $(op --version)"
else
  echo "op CLI already installed: $(op --version)"
fi

# Prompt for OP_SERVICE_ACCOUNT_TOKEN if not already persisted
OP_ENV_FILE="/etc/op-service-account.env"
if [[ ! -f "$OP_ENV_FILE" ]]; then
  echo ""
  echo "--- 1Password service account setup ---"
  echo "Enter OP_SERVICE_ACCOUNT_TOKEN for pedrogpt (stored in $OP_ENV_FILE):"
  read -rsp "Token: " OP_TOKEN
  echo ""
  echo "OP_SERVICE_ACCOUNT_TOKEN=$OP_TOKEN" | sudo tee "$OP_ENV_FILE" > /dev/null
  sudo chmod 600 "$OP_ENV_FILE"
  echo "Token saved to $OP_ENV_FILE"
else
  echo "OP service account config already exists at $OP_ENV_FILE"
fi

# ---------------------------------------------------------------------------
# CUDA check — RTX 5090 (Blackwell, sm_120) requires CUDA 12.8.
# Use CUDA 12.8 specifically — NOT CUDA 13.x: its MMQ (matrix-multiply-quantized)
# kernels crash on Blackwell and force a slow cuBLAS fallback (~5-6x slower).
# DO NOT use apt install nvidia-cuda-toolkit — it ships an old version.
# Install from NVIDIA's official repo:
#
#   wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
#   sudo dpkg -i cuda-keyring_1.1-1_all.deb
#   sudo apt-get update
#   sudo apt-get install -y cuda-toolkit-12-8
#   echo 'export PATH=/usr/local/cuda-12.8/bin:$PATH' >> ~/.bashrc
#   source ~/.bashrc
#
# Then re-run this script.
# ---------------------------------------------------------------------------
CUDA_FLAG=""
CUDA_ARCH_FLAG=""

if ! command -v nvcc &>/dev/null; then
  echo ""
  echo "ERROR: nvcc not found — CUDA toolkit is not installed or not in PATH."
  echo ""
  echo "For RTX 5090 (Blackwell) install CUDA 12.8+ from NVIDIA's official repo:"
  echo "  wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb"
  echo "  sudo dpkg -i cuda-keyring_1.1-1_all.deb"
  echo "  sudo apt-get update && sudo apt-get install -y cuda-toolkit-12-8"
  echo "  echo 'export PATH=/usr/local/cuda/bin:\$PATH' >> ~/.bashrc && source ~/.bashrc"
  echo ""
  echo "Then re-run this script. Aborting."
  exit 1
else
  CUDA_VERSION=$(nvcc --version | grep -oP 'release \K[0-9]+\.[0-9]+')
  CUDA_MAJOR=$(echo "$CUDA_VERSION" | cut -d. -f1)
  CUDA_MINOR=$(echo "$CUDA_VERSION" | cut -d. -f2)
  echo "CUDA $CUDA_VERSION detected"

  # RTX 5090 (Blackwell sm_120) requires CUDA 12.8.
  if [[ "$CUDA_MAJOR" -lt 12 ]] || [[ "$CUDA_MAJOR" -eq 12 && "$CUDA_MINOR" -lt 8 ]]; then
    echo ""
    echo "ERROR: CUDA $CUDA_VERSION is too old for RTX 5090 (Blackwell)."
    echo "Blackwell (sm_120) requires CUDA 12.8."
    echo ""
    echo "Upgrade:"
    echo "  sudo apt-get install -y cuda-toolkit-12-8"
    echo "  (add NVIDIA's repo first if not already done — see above)"
    echo ""
    echo "Aborting."
    exit 1
  fi

  # CUDA 13.x: MMQ kernels crash on Blackwell and fall back to slow cuBLAS. Warn but continue.
  if [[ "$CUDA_MAJOR" -ge 13 ]]; then
    echo ""
    echo "WARNING: CUDA $CUDA_VERSION (13.x) is known to crash the MMQ kernels on Blackwell"
    echo "and silently fall back to cuBLAS — measured ~5-6x slower. Use CUDA 12.8 for the 5090."
    echo ""
  fi

  echo "CUDA $CUDA_VERSION OK — building with GGML_CUDA=ON, sm_120 (RTX 5090 Blackwell)"
  CUDA_FLAG="-DGGML_CUDA=ON"
  CUDA_ARCH_FLAG="-DCMAKE_CUDA_ARCHITECTURES=120"
fi

# ---------------------------------------------------------------------------
# Clone or update llama.cpp
# ---------------------------------------------------------------------------
if [[ -d "$LLAMA_DIR" && "$REBUILD" == "false" ]]; then
  echo "--- Updating existing llama.cpp clone ---"
  sudo git -C "$LLAMA_DIR" fetch origin
  sudo git -C "$LLAMA_DIR" reset --hard origin/master
else
  echo "--- Cloning llama.cpp ---"
  sudo rm -rf "$LLAMA_DIR"
  sudo git clone https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
echo "--- Building llama.cpp (this takes a few minutes) ---"
cd "$LLAMA_DIR"

# Remove any stale build dir so cached CMake vars (e.g. a previously-forced
# cuBLAS, or an old CUDA arch) can't leak into this build.
sudo rm -rf build

sudo cmake -B build \
  ${CUDA_FLAG} \
  ${CUDA_ARCH_FLAG} \
  -DCMAKE_CUDA_COMPILER=/usr/local/cuda-12.8/bin/nvcc \
  -DGGML_CUDA_FORCE_CUBLAS=OFF \
  -DCUDAToolkit_ROOT=/usr/local/cuda-12.8 \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_SERVER_VERBOSE=OFF

sudo cmake --build build --config Release -j "$(nproc)"

# Sanity check: cuBLAS must NOT be forced on, or the fast MMQ path is bypassed.
if grep -q 'GGML_CUDA_FORCE_CUBLAS:.*=ON' "$LLAMA_DIR/build/CMakeCache.txt" 2>/dev/null; then
  echo "WARNING: GGML_CUDA_FORCE_CUBLAS is ON in the build cache — expect slow inference."
fi

echo "--- Build complete ---"
ls -lh "$LLAMA_DIR/build/bin/"

# ---------------------------------------------------------------------------
# Model directory
# ---------------------------------------------------------------------------
sudo mkdir -p "$MODEL_DIR"
echo "Models go in: $MODEL_DIR"
echo "Use ./switch-model.sh to download and activate a model."

# ---------------------------------------------------------------------------
# Environment config (editable without touching the service file)
# ---------------------------------------------------------------------------
if [[ ! -f "$ENV_FILE" ]]; then
  echo "--- Creating $ENV_FILE ---"
  sudo tee "$ENV_FILE" > /dev/null <<'EOF'
# llama-server runtime configuration — dedicated Qwen3.6-27B MTP single-model server.
# Edit this file then: sudo systemctl restart llama-server
#
# This box runs ONE tuned model with Multi-Token Prediction (MTP) self-speculative
# decoding. MTP requires a single stream (N_PARALLEL=1) — it cannot share VRAM with
# multi-slot continuous batching. Router/preset mode is retired (kept as rollback only).

# Local GGUF path (downloaded by switch-model.sh / hf download). The MTP head is baked
# into this checkpoint, so no separate draft model is needed.
MODEL=/opt/models/qwen3.6-27b-mtp/Qwen3.6-27B-MTP-UD-Q4_K_XL.gguf

# API model id advertised at /v1/models and required in request "model" fields.
MODEL_ALIAS=qwen3.6-27b-mtp

# HuggingFace cache directory (on the 2TB drive)
HF_HOME=/opt/models/cache

# GPU layers (99 = all layers on GPU; the dense 27B fits fully in 32GB VRAM)
N_GPU_LAYERS=99

# Context window (tokens). 65536 fits alongside Q4 weights + MTP head + q8_0 KV cache.
# Qwen3.6's hybrid DeltaNet/GQA layout keeps the KV cache small; 131072 also fits if needed.
N_CTX=65536

# Parallel request slots — MUST be 1 for MTP.
N_PARALLEL=1

# Batch sizes: -b logical token budget, -ub physical micro-batch shipped to the GPU.
# Larger UBATCH improves prompt-processing (prefill) throughput; 1024 is safe on a 5090.
BATCH=2048
UBATCH=1024

# MTP self-speculative decoding. SPEC_DRAFT_N = max draft tokens per step (start 2, try 3).
# Confirm the exact spec-type spelling for your build: llama-server --help | grep -i spec
SPEC_TYPE=draft-mtp
SPEC_DRAFT_N=3

# KV cache quantization (q8_0 halves KV VRAM at negligible quality cost). Requires flash-attn.
# K and V MUST match or llama.cpp silently falls back to the slow attention path.
CACHE_TYPE_K=q8_0
CACHE_TYPE_V=q8_0

# Sampling (Unsloth non-thinking recommendation for Qwen3.6).
TEMP=0.7
TOP_K=20
TOP_P=0.8
PRESENCE_PENALTY=1.5
MIN_P=0.0

# Server port (Tailscale serve maps this to HTTPS)
PORT=8000

# HuggingFace token (required for model downloads — keep this file root-only)
HF_TOKEN=your_token_here
EOF
  echo "Edit $ENV_FILE before starting the service."
else
  echo "--- $ENV_FILE already exists, skipping ---"
  echo "    (single-model MTP mode reads MODEL/MODEL_ALIAS/SPEC_TYPE etc. — see the template above"
  echo "     if upgrading from router/MoE mode, replace the old env file)"
fi

# ---------------------------------------------------------------------------
# Wrapper script — launches the dedicated Qwen3.6-27B MTP single-model server.
# Installed from the committed run-server.sh (single source of truth, also used
# by deploy-presets.sh). Reads /etc/llama-server.env.
# ---------------------------------------------------------------------------
WRAPPER="$LLAMA_DIR/run-server.sh"
echo "--- Installing launcher wrapper $WRAPPER ---"
sudo cp "$SCRIPT_DIR/run-server.sh" "$WRAPPER"
sudo chmod +x "$WRAPPER"

# ---------------------------------------------------------------------------
# Systemd service
# ---------------------------------------------------------------------------
echo "--- Installing systemd service ---"
sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=llama.cpp Server
Documentation=https://github.com/ggml-org/llama.cpp
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$LLAMA_DIR/run-server.sh
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=llama-server
SupplementaryGroups=render video

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable llama-server

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Download the MTP model (~18 GB to /opt/models/qwen3.6-27b-mtp):"
echo "       hf download unsloth/Qwen3.6-27B-MTP-GGUF --include '*UD-Q4_K_XL*' \\"
echo "         --local-dir /opt/models/qwen3.6-27b-mtp"
echo "     Then set MODEL= in $ENV_FILE to the downloaded .gguf path."
echo ""
echo "  2. Confirm the MTP flag spelling matches this build:"
echo "       $LLAMA_DIR/build/bin/llama-server --help | grep -i spec"
echo ""
echo "  3. Start the server:"
echo "       sudo systemctl start llama-server"
echo "       sudo systemctl status llama-server"
echo ""
echo "  4. Verify it's serving the MTP model and metrics:"
echo "       curl http://localhost:8000/v1/models | jq '.data[].id'   # -> qwen3.6-27b-mtp"
echo "       curl http://localhost:8000/metrics | head -20"
echo ""
echo "  Logs: sudo journalctl -u llama-server -f"
