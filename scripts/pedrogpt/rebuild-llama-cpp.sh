#!/bin/bash

# Rebuild llama.cpp on pedrogpt with CUDA support.
#
# Run locally (over SSH) or directly on pedrogpt.
#
# Usage:
#   ./rebuild-llama-cpp.sh              # Build from this machine via SSH
#   ./rebuild-llama-cpp.sh --local      # Run directly on pedrogpt
#   ./rebuild-llama-cpp.sh --arch 120   # Override CUDA arch (default: auto-detect; 5090 = 120)

set -euo pipefail

LLAMA_DIR="/opt/llama.cpp"
REMOTE_HOST="pedrogpt"
CUDA_ARCH=""
LOCAL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)  LOCAL=true; shift ;;
    --arch)   CUDA_ARCH="$2"; shift 2 ;;
    --host)   REMOTE_HOST="$2"; shift 2 ;;
    -h|--help)
      head -9 "$0" | tail -7
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Build function — runs on pedrogpt
# ---------------------------------------------------------------------------
do_build() {
  local arch="$1"

  # Auto-detect CUDA architecture if not specified
  if [[ -z "$arch" ]]; then
    if command -v nvidia-smi &>/dev/null; then
      local compute
      compute=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | tr -d '.')
      arch="$compute"
      echo "Auto-detected CUDA architecture: sm_$arch"
    else
      echo "ERROR: Cannot detect GPU. Specify --arch manually (RTX 5090 = --arch 120)"
      exit 1
    fi
  fi

  echo "=== Rebuilding llama.cpp (CUDA arch: sm_$arch) ==="
  echo ""

  cd "$LLAMA_DIR"

  echo "--- Pulling latest source ---"
  sudo git config --global --add safe.directory "$LLAMA_DIR" 2>/dev/null || true
  sudo git pull

  echo ""
  echo "--- CUDA toolkit ---"
  nvcc --version

  echo ""
  echo "--- Building (this may take a few minutes) ---"
  # Clean stale build dir so cached CMake vars (forced cuBLAS, old arch) don't leak.
  sudo rm -rf build
  # Pin the CUDA compiler by absolute path — sudo scrubs PATH, so a `which nvcc`
  # in the user's shell won't be visible to the sudo'd cmake otherwise.
  sudo cmake -B build \
    -DGGML_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES="$arch" \
    -DCMAKE_CUDA_COMPILER=/usr/local/cuda-12.8/bin/nvcc \
    -DGGML_CUDA_FORCE_CUBLAS=OFF \
    -DCUDAToolkit_ROOT=/usr/local/cuda-12.8
  sudo cmake --build build --config Release -j"$(nproc)"

  # cuBLAS must not be forced on, or the fast MMQ path is bypassed (~5-6x slower).
  if grep -q 'GGML_CUDA_FORCE_CUBLAS:.*=ON' "$LLAMA_DIR/build/CMakeCache.txt" 2>/dev/null; then
    echo "WARNING: GGML_CUDA_FORCE_CUBLAS is ON — expect slow inference on Blackwell."
  fi

  echo ""
  echo "--- Verifying ---"
  "$LLAMA_DIR/build/bin/llama-server" --version

  echo ""
  echo "--- Restarting llama-server ---"
  sudo systemctl restart llama-server
  sleep 3

  if sudo systemctl is-active --quiet llama-server; then
    echo "=== Build complete, llama-server running ==="
  else
    echo "WARNING: llama-server failed to start after rebuild"
    sudo journalctl -u llama-server -n 20 --no-pager
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Run locally on pedrogpt or remotely via SSH
# ---------------------------------------------------------------------------
if [[ "$LOCAL" == "true" ]]; then
  do_build "$CUDA_ARCH"
else
  echo "=== Rebuilding llama.cpp on $REMOTE_HOST via SSH ==="
  # Export the function and run it remotely
  ARCH_ARG=""
  [[ -n "$CUDA_ARCH" ]] && ARCH_ARG="--arch $CUDA_ARCH"
  scp "$0" "$REMOTE_HOST:/tmp/rebuild-llama-cpp.sh"
  ssh -t "$REMOTE_HOST" "bash /tmp/rebuild-llama-cpp.sh --local $ARCH_ARG"
fi
