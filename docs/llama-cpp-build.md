# Building llama.cpp for RTX 5090 (Blackwell)

Build instructions for llama.cpp with CUDA support on the pedrogpt machine (RTX 5090, sm_89).

## Prerequisites

- **CUDA 12.8+** - RTX 5090 (Blackwell/sm_89) requires CUDA 12.8 or newer
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
export PATH=/usr/local/cuda/bin:$PATH
```

## Build Commands

### Full build from source

```bash
# Clone (or update existing)
git clone https://github.com/ggml-org/llama.cpp.git /opt/llama.cpp
cd /opt/llama.cpp

# Configure with CUDA for RTX 5090 (sm_89)
cmake -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES=89 \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_SERVER_VERBOSE=OFF

# Build (uses all available cores)
cmake --build build --config Release -j$(nproc)

# Verify
./build/bin/llama-server --version
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

# Pull latest and rebuild
git pull
cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120
cmake --build build --config Release -j$(nproc)

# Restart service
sudo systemctl restart llama-server
```

## Architecture Flags

| GPU | sm_ | CUDA Arch |
|-----|-----|-----------|
| RTX 5090 | 96 | Blackwell |
| RTX 4090 | 89 | Ada Lovelace |
| RTX 3090/4090 | 86 | Ampere |
| A100 | 80 | Ampere |

## Troubleshooting

### CUDA version too old

```
ERROR: CUDA 12.x is too old for RTX 5090 (Blackwell).
Blackwell (sm_89) requires CUDA 12.8 or newer.
```

**Fix**: Install CUDA 12.8+ from NVIDIA's repository (see above).

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

## Embeddings

Enable embeddings with these flags in the systemd service:

```ini
--embeddings \
--pooling mean
```

- `--pooling mean` - Average all token embeddings (OAI compatible, recommended)
- `--pooling cls` - Use first token (CLS) - sometimes better for classification
- `--pooling none` - Return per-token embeddings (not OAI compatible)

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

# Test embeddings
curl http://100.121.229.114:8080/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model": "glm-4.7-flash", "input": "Hello world"}'
```