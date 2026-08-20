#!/bin/bash

# Setup llama.cpp on Ubuntu (pedrogpt) with CUDA support.
# Builds llama-server and installs it as a systemd service that
# exposes Prometheus metrics at :8000/metrics?model=<id> (router mode requires the param).
#
# Usage: ./setup-llama-cpp-ubuntu.sh [--rebuild]
#   --rebuild  Force a clean rebuild even if llama.cpp is already installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLAMA_DIR="/opt/llama.cpp"
MODEL_DIR="/opt/models"
ENV_FILE="/etc/llama-server.env"
MODELS_PRESET_PATH="/etc/llama-server-models.ini"
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
# llama-server runtime configuration — ROUTER mode (two models, one resident).
# Edit this file then: sudo systemctl restart llama-server
#
# Per-model tuning (GGUF paths, ctx, sampling, MTP flags) lives in the preset INI
# below, NOT here. Source of truth: scripts/pedrogpt/presets/router.ini in pedro-ops,
# deployed by deploy-presets.sh. See presets/README.md for the full flag mapping.

# Model preset INI defining every servable model.
MODELS_PRESET=/etc/llama-server-models.ini

# Max models resident in VRAM at once. MUST stay 1: qwen3.6-27b-mtp alone measures
# 27.9 GB of 32.6 GB, and two 27B Q4 models are 35.5 GB of weights before any KV cache.
# Raising this will OOM the GPU. Past this limit the router LRU-evicts.
MODELS_MAX=1

# Autoload a model when a request names one that is not resident (1 = on).
# With MODELS_MAX=1 this is what makes model switching work at all.
MODELS_AUTOLOAD=1

# HuggingFace cache directory (on the 2TB drive)
HF_HOME=/opt/models/cache

# Destination for llama.cpp's own `-hf` pulls. Outranks HF_HOME for that purpose.
LLAMA_CACHE=/opt/models/cache/llama.cpp

# Server port (Tailscale serve maps this to HTTPS)
PORT=8000

# HuggingFace token (required for model downloads — keep this file root-only)
HF_TOKEN=your_token_here
EOF
  echo "Edit $ENV_FILE before starting the service."
else
  echo "--- $ENV_FILE already exists, skipping ---"
  echo "    (router mode reads MODELS_PRESET/MODELS_MAX/MODELS_AUTOLOAD — see the template above."
  echo "     If upgrading from single-model mode, the old MODEL/MODEL_ALIAS/SPEC_TYPE/N_CTX vars"
  echo "     are no longer read; per-model tuning moved to \$MODELS_PRESET.)"
fi

# ---------------------------------------------------------------------------
# Wrapper script — launches llama-server in router mode (no -m; models from the preset INI).
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
echo "  1. Download both models (~18 GB each):"
echo "       hf download unsloth/Qwen3.6-27B-MTP-GGUF --include '*UD-Q4_K_XL*' \\"
echo "         --local-dir /opt/models/qwen3.6-27b-mtp"
echo "       hf download unsloth/Qwen3.8-27B-GGUF --include 'Qwen3.8-27B-UD-Q4_K_XL.gguf' \\"
echo "         --local-dir /opt/models/qwen3.8-27b"
echo "     Paths must match the model= keys in the preset INI (step 2)."
echo ""
echo "  2. Deploy the router preset — the server will NOT start without it:"
echo "       # from a checkout of pedro-ops, on your workstation:"
echo "       ./scripts/pedrogpt/deploy-presets.sh --env /tmp/llama-server.env"
echo "     That installs presets/router.ini to $MODELS_PRESET_PATH."
echo ""
echo "  3. Confirm this build has router support and the MTP flag spelling:"
echo "       $LLAMA_DIR/build/bin/llama-server --help | grep -E -- '--models|spec-type'"
echo ""
echo "  4. Start the server:"
echo "       sudo systemctl start llama-server"
echo "       sudo systemctl status llama-server"
echo ""
echo "  5. Verify both models are registered and metrics work:"
echo "       curl http://localhost:8000/v1/models | jq '.data[].id'"
echo "         # -> qwen3.6-27b-mtp, qwen3.8-27b"
echo "       curl http://localhost:8000/health                        # 200, no ?model= needed"
echo "       curl 'http://localhost:8000/metrics?model=qwen3.6-27b-mtp&autoload=false' | head"
echo "         # NOTE: plain /metrics returns HTTP 400 in router mode — ?model= is required"
echo ""
echo "  Logs: sudo journalctl -u llama-server -f"
