# Building llama.cpp for RTX 5090 (Blackwell)

Build instructions for llama.cpp with CUDA support on the pedrogpt machine (RTX 5090, **sm_120**).

> **The single most important fact:** the RTX 5090 is Blackwell = compute capability **12.0** =
> `CMAKE_CUDA_ARCHITECTURES=120`. It is **not** sm_89 (that's the Ada RTX 4090). Building for the
> wrong arch — or with CUDA 13.x, or with cuBLAS forced on — silently falls back to a slow path and
> is the most common cause of inexplicably low tok/s on this card.

## Prerequisites

- **CUDA 12.8 (exactly this line — not 13.x)** - RTX 5090 (Blackwell/sm_120) requires CUDA 12.8.
  CUDA 13.x's MMQ kernels crash on Blackwell and fall back to cuBLAS (~5-6x slower).
- **Ubuntu 24.04** or similar Linux distribution
- **Build tools**: cmake, git, build-essential

## Install CUDA 12.8 (if not already installed)

```bash
# Add NVIDIA's CUDA repository
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt-get update

# Install CUDA toolkit
sudo apt-get install -y cuda-toolkit-12-8

# Add to PATH (add to ~/.bashrc for persistence)
export PATH=/usr/local/cuda-12.8/bin:$PATH
```

## Build Commands

### Full build from source

```bash
# Clone (or update existing)
git clone https://github.com/ggml-org/llama.cpp.git /opt/llama.cpp
cd /opt/llama.cpp

# Remove any stale build dir first — cached CMake vars (forced cuBLAS, old arch)
# leak across reconfigures and are a common cause of a slow rebuild.
rm -rf build

# Configure with CUDA for RTX 5090 (Blackwell, sm_120)
cmake -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES=120 \
  -DGGML_CUDA_FORCE_CUBLAS=OFF \
  -DCUDAToolkit_ROOT=/usr/local/cuda-12.8 \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_SERVER_VERBOSE=OFF

# Build (uses all available cores)
cmake --build build --config Release -j$(nproc)

# Verify the build, and that cuBLAS was NOT forced on
./build/bin/llama-server --version
grep FORCE_CUBLAS build/CMakeCache.txt   # expect: ...=OFF
```

### Using the rebuild script (recommended)

From your local machine:

```bash
cd scripts/pedrogpt
./rebuild-llama-cpp.sh
```

Or run directly on pedrogpt:

```bash
ssh soypete@100.121.229.114
cd /opt/llama.cpp

# Pull latest and rebuild (clean build dir first)
git pull
rm -rf build
cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120 \
  -DGGML_CUDA_FORCE_CUBLAS=OFF -DCUDAToolkit_ROOT=/usr/local/cuda-12.8
cmake --build build --config Release -j$(nproc)

# Restart service
sudo systemctl restart llama-server
```

## Architecture Flags

`CMAKE_CUDA_ARCHITECTURES` takes the compute capability with the dot removed (12.0 → 120).

| GPU | Arch family | Compute cap | `CMAKE_CUDA_ARCHITECTURES` |
|-----|-------------|-------------|----------------------------|
| RTX 5090 | Blackwell | 12.0 | **120** |
| RTX 4090 | Ada Lovelace | 8.9 | 89 |
| RTX 3090 | Ampere | 8.6 | 86 |
| A100 | Ampere | 8.0 | 80 |

## Troubleshooting

### Inexplicably slow inference (e.g. ~11 tok/s on a 5090)

A 4-bit ~27B model on a 5090 should generate in the high double / triple digits of tok/s. If you see
~10 tok/s, the CUDA backend is almost certainly mis-built. Check, in order:

1. **Wrong arch / PTX JIT.** Built for sm_89 (4090) instead of sm_120 forces a slow PTX recompile or
   wrong kernels. Rebuild with `-DCMAKE_CUDA_ARCHITECTURES=120`.
2. **CUDA 13.x.** Its MMQ kernels crash on Blackwell → cuBLAS fallback (~5-6x slower prefill). Use the
   CUDA 12.8 toolkit (`nvcc --version` should show 12.8).
3. **cuBLAS forced on.** `grep FORCE_CUBLAS build/CMakeCache.txt` must show `OFF`. A stale `build/`
   dir is the usual culprit — `rm -rf build` and reconfigure.
4. **Not fully offloaded.** Confirm `-ngl 99` (or `-1`) and that `nvidia-smi` shows the weights in
   VRAM, not split to CPU.

### MXFP4 PTX build error on sm_120

Some commits fail to compile MXFP4 kernels for sm_120
(`Instruction 'mma with block scale' not supported on .target 'sm_120'`), and
`-DGGML_CUDA_MXFP4=OFF` does not reliably disable it (issue #19662). Fix: ensure CUDA 12.8 (not 13.x)
and build a recent master where it's resolved. This only affects MXFP4 models (e.g. GPT-OSS) at build
time — Qwen3.6 GGUFs are K-quants and unaffected at runtime.

### CUDA version too old

```
ERROR: CUDA 12.x is too old for RTX 5090 (Blackwell).
Blackwell (sm_120) requires CUDA 12.8.
```

**Fix**: Install the CUDA 12.8 toolkit from NVIDIA's repository (see above). Do not use 13.x.

### OOM on model load

For MoE models (GLM-4.7-Flash, Qwen3-Next-80B, Nemotron-120B), use expert offload:

```bash
# In /etc/llama-server.env
OVERRIDE_TENSOR=".ffn_.*_exps.=CPU"
FLASH_ATTN=1
```

### Service fails to start

Check logs:
```bash
sudo journalctl -u llama-server -n 50
```

## Model Files Location

- **Build**: `/opt/llama.cpp/build/bin/llama-server`
- **Models**: `/opt/models/`
- **Config**: `/etc/llama-server.env`
- **Service**: `/etc/systemd/system/llama-server.service`

## Embeddings — run a separate server, not this one

**Do not add `--embeddings` to the MTP chat server.** The embeddings output graph is incompatible
with the MTP spec-decoding graph and crashes the server on load
(`GGML_ASSERT(... "missing result_norm/result_embd tensor")`). One process cannot serve both.

Embeddings run on a dedicated CPU llama.cpp server (the same `llama-server` binary works — embeddings
only fail when MTP is *also* enabled). In this stack that's a sidecar in the twitch-bot pod
(`iam_pedro/deployment/embed/`, model `nomic-embed-text`, 768-dim) launched with:

```
llama-server -m nomic-embed-text.gguf --alias nomic-embed-text \
  --embeddings --pooling mean --ctx-size 2048 --ubatch-size 2048 --batch-size 2048
```

- `--pooling mean` - average all token embeddings (OAI compatible, recommended)
- `--ubatch-size >= --batch-size` is required for non-causal embedding models
- `--pooling cls` / `none` - first-token / per-token (per-token is not OAI compatible)

## Quick Reference

```bash
# Rebuild and restart
./rebuild-llama-cpp.sh

# Check status
ssh soypete@100.121.229.114 "sudo systemctl status llama-server"

# View logs
ssh soypete@100.121.229.114 "sudo journalctl -u llama-server -f"

# Check GPU
ssh soypete@100.121.229.114 "nvidia-smi"

# Test embeddings (separate sidecar on :8081, NOT the chat server)
curl http://localhost:8081/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model": "nomic-embed-text", "input": "Hello world"}'
```