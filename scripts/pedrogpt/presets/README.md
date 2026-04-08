# llama.cpp Model Presets

Model preset configurations for pedrogpt (RTX 5090, 32GB VRAM, 64GB RAM).

Ref: [Model Management in llama.cpp](https://huggingface.co/blog/ggml-org/model-management-in-llamacpp)

## Presets

| Preset | Section Name | Model | Type | Use Case |
|--------|-------------|-------|------|----------|
| `text.ini` | `gpt-oss-20b` | GPT-OSS 20B Q4_K_M | Dense | General chat, reasoning (default) |
| `text.ini` | `nemotron-3-super-120b` | Nemotron-3-Super 120B-A12B UD-Q4_K_XL | MoE (12B active) | Heavy reasoning |
| `code.ini` | `qwen3-next-80b` | Qwen3-Next 80B-A3B UD-Q4_K_XL | MoE (3B active) | Code gen, expert offload |
| `code.ini` | `qwen3-coder-30b` | Qwen3-Coder 30B-A3B Q4_K_M | MoE (3B active) | Code gen, fully GPU |
| `vision.ini` | `qwen2.5-vl-32b` | Qwen2.5-VL 32B Q4_K_M | Dense | Image understanding, OCR |
| `tts.ini` | `qwen2.5-omni-7b` | Qwen2.5-Omni 7B | Dense | Text-to-speech (port 8001) |
| `all-models.ini` | all of the above | — | Router | Dynamic switching via API |

## How It Works

With `--models-preset`, llama-server registers all models from the INI file.
You switch models by setting the `"model"` field in your API request to the
**section name** from the INI. The server loads/unloads on demand:

```bash
# Start server with all models registered
llama-server \
  --models-preset /opt/llama.cpp/presets/all-models.ini \
  --models-max 1 \
  --host 0.0.0.0 --port 8080 \
  --metrics

# Use the default model (gpt-oss-20b loads on startup)
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-oss-20b", "messages": [{"role": "user", "content": "hello"}]}'

# Switch to coding model — server unloads gpt-oss, loads qwen3-coder
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen3-coder-30b", "messages": [{"role": "user", "content": "write a go function"}]}'
```

With `--models-max 1`, only one model occupies VRAM at a time. When you
request a different model, the server evicts the current model from VRAM
and loads the new one (~30s swap time).

### MoE expert offload (Qwen3-Next 80B)

For large MoE models, offload expert layers to system RAM while keeping
attention on GPU. Add `-ot` to the CLI (not in the INI):

```bash
llama-server \
  --models-preset /opt/llama.cpp/presets/code.ini \
  -ot ".ffn_.*_exps.=CPU" \
  --flash-attn on \
  --host 0.0.0.0 --port 8080 \
  --metrics
```

> **Note:** `--flash-attn` requires an explicit value (`on`, `off`, or `auto`). Omitting it causes a startup error.

### TTS (separate process on port 8001)

```bash
llama-server \
  --models-preset /opt/llama.cpp/presets/tts.ini \
  --host 0.0.0.0 --port 8001 \
  --metrics
```

### Deploy to pedrogpt

```bash
# Deploy presets only
./scripts/pedrogpt/deploy-presets.sh

# Deploy and activate a preset
./scripts/pedrogpt/deploy-presets.sh --preset all
./scripts/pedrogpt/deploy-presets.sh --preset text
./scripts/pedrogpt/deploy-presets.sh --preset code
```

## Downloading Models

Models live in `/opt/models/` on pedrogpt. Download with `huggingface-cli`:

```bash
pip install huggingface_hub hf_transfer

# Text
hf download unsloth/gpt-oss-20b-GGUF \
  --include "*Q4_K_M*" \
  --local-dir /opt/models/gpt-oss-20b

# Text (heavy)
hf download unsloth/NVIDIA-Nemotron-3-Super-120B-A12B-GGUF \
  --include "*UD-Q4_K_XL*" \
  --local-dir /opt/models/nemotron-3-super-120b

# Coding
hf download unsloth/Qwen3-Next-80B-A3B-Instruct-GGUF \
  --include "*UD-Q4_K_XL*" \
  --local-dir /opt/models/qwen3-next-80b

# Coding (lite)
hf download unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF \
  --include "*Q4_K_M*" \
  --local-dir /opt/models/qwen3-coder-30b

# Vision
hf download Qwen/Qwen2.5-VL-32B-Instruct-GGUF \
  --include "*Q4_K_M*" \
  --local-dir /opt/models/qwen2.5-vl-32b

# TTS
hf download Qwen/Qwen2.5-Omni-7B-GGUF \
  --local-dir /opt/models/qwen2.5-omni-7b
```

If downloads get stuck, set `HF_HUB_ENABLE_HF_TRANSFER=1` for faster transfers.

## Finding New Models

### Step 1: Check LiveBench scores

Go to [LiveBench](https://livebench.ai/#/?highunseenbias=true) to find
top-performing models:

1. Enable **"High Unseen Bias"** to filter for models tested on unseen data
2. Sort by **Overall** or by category (Coding, Reasoning, Math, etc.)
3. Look for open-weight models — MoE with low active params are ideal
4. Note the model name (e.g., "Qwen3-Next-80B-A3B")

### Step 2: Find GGUF quantizations on HuggingFace

1. Go to [HuggingFace](https://huggingface.co)
2. Search for `<model-name> GGUF` (e.g., "Qwen3-Next-80B-A3B GGUF")
3. Look for repos by **unsloth** or **bartowski** — they provide reliable quants
4. For MoE models, prefer **UD-Q4_K_XL** (unsloth dynamic quant) — applies
   higher precision to important layers automatically
5. Quant sizing guide:

| Quantization | Quality | Notes |
|-------------|---------|-------|
| UD-Q4_K_XL | Excellent | Unsloth dynamic quant, best for MoE |
| UD-Q2_K_XL | Good | Unsloth dynamic 2-bit, smaller |
| Q8_0 | Near-lossless | ~1.1x active params in GB |
| Q6_K | Excellent | ~0.85x active params in GB |
| Q5_K_M | Very good | ~0.73x active params in GB |
| Q4_K_M | Good | ~0.6x active params in GB |

### Step 3: Size for pedrogpt

**32GB VRAM:**
- **Dense**: Up to ~25B at Q4_K_M, ~20B at Q8_0
- **MoE**: 80-120B+ total params — only active params matter.
  Use `-ot ".ffn_.*_exps.=CPU"` to put experts in 64GB RAM.
- **Context**: Use `--flash-attn` to push to 64K+ on small-active MoE models.

**64GB system RAM:**
- Offload MoE experts: `-ot ".ffn_.*_exps.=CPU"`
- KV cache spills to RAM for long contexts
- Set `n-gpu-layers` to control GPU/RAM split

### Step 4: Add to a preset and deploy

1. Download the model:

```bash
hf download org/new-model-GGUF \
  --include "*Q4_K_M*" \
  --local-dir /opt/models/new-model
```

2. Add a section to the relevant preset INI:

```ini
[new-model]
model = /opt/models/new-model/new-model-Q4_K_M.gguf
ctx-size = 16384
```

3. Deploy and test:

```bash
./scripts/pedrogpt/deploy-presets.sh --preset all

curl http://pedrogpt:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "new-model", "messages": [{"role": "user", "content": "Hello"}]}'
```

## Preset INI Format Reference

```ini
version = 1

# Global defaults (apply to all models unless overridden)
[*]
n-gpu-layers = -1
ctx-size = 8192
jinja = true

# Model section — the section name is what you pass as "model" in API requests
[my-model-name]
model = /opt/models/my-model/my-model-Q4_K_M.gguf
ctx-size = 16384                # Context size
n-gpu-layers = 99               # GPU layer count (-1 = all)
flash-attn = true               # Flash attention
load-on-startup = true          # Auto-load when server starts
stop-timeout = 30               # Seconds before force-kill on swap
chat-template = chatml          # Override chat template
temp = 0.6                      # Sampling temperature
top-p = 0.95                    # Top-p sampling
model-draft = /path/to.gguf     # Speculative decoding draft model
```

Keys correspond to llama-server CLI args (without leading `--`).
Both short forms (`c`, `ngl`) and env var names (`LLAMA_ARG_N_GPU_LAYERS`) work.

**Note:** Router-level args (`--host`, `--port`, `-ot`) go on the CLI, not in
the INI. The INI defines per-model settings only.
