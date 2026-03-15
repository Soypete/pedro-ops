# llama.cpp Model Presets

Model preset configurations for pedrogpt (RTX 5090, 32GB VRAM, 64GB RAM).

## Presets

| Preset | Model | Size (Q4_K_M) | Type | Use Case |
|--------|-------|---------------|------|----------|
| `text.ini` | GPT-OSS 20B | 11.6 GB | Dense | General chat, writing, reasoning |
| `code.ini` | Qwen3-Coder 30B-A3B | 18.6 GB | MoE | Code generation, review, debugging |
| `vision.ini` | Qwen2.5-VL 32B | ~18 GB | Dense | Image understanding, OCR, visual QA |
| `all-models.ini` | All of the above | — | Router | Combined preset for model switching |

## Usage

### Single model (standalone)

```bash
llama-server \
  --models-preset ./presets/text.ini \
  --host 0.0.0.0 --port 8080 \
  --metrics --no-webui
```

### Router mode (all models, swap on demand)

```bash
llama-server \
  --models-preset ./presets/all-models.ini \
  --models-max 1 \
  --host 0.0.0.0 --port 8080 \
  --metrics --no-webui
```

With `--models-max 1`, the server keeps one model loaded and swaps when a
request targets a different model via the `model` field in the API request.

### Deploy to pedrogpt

```bash
# From this repo root:
./scripts/pedrogpt/deploy-presets.sh
```

See `deploy-presets.sh` for options (SCP vs Taildrop, preset selection).

## Finding Models

### Step 1: Check LiveBench scores

Go to [LiveBench](https://livebench.ai/#/?highunseenbias=true) to find
top-performing models. Filter by:

1. Click **"High Unseen Bias"** to filter for models tested on unseen data
2. Sort by **Overall** score or by category (Coding, Reasoning, Math, etc.)
3. Look for open-weight models in the 20B-35B parameter range
4. Note the model name (e.g., "Qwen3-Coder-30B-A3B")

### Step 2: Find GGUF quantizations on HuggingFace

Once you've identified a model on LiveBench:

1. Go to [HuggingFace](https://huggingface.co)
2. Search for `<model-name> GGUF` (e.g., "Qwen3-Coder-30B-A3B GGUF")
3. Look for repos by **unsloth** or **bartowski** — they provide reliable quantizations
4. Check the quant table for file sizes that fit your hardware:

| Quantization | Quality | VRAM Rule of Thumb |
|-------------|---------|-------------------|
| Q8_0 | Near-lossless | ~1.1x model params in GB |
| Q6_K | Excellent | ~0.85x model params in GB |
| Q5_K_M | Very good | ~0.73x model params in GB |
| Q4_K_M | Good (recommended) | ~0.6x model params in GB |
| Q3_K_M | Acceptable | ~0.5x model params in GB |

### Step 3: Size your model for pedrogpt

With 32GB VRAM:

- **Dense models**: Up to ~25B at Q4_K_M, ~20B at Q8_0
- **MoE models**: Total params can be much larger (30-70B) since only active
  params load into VRAM. Check the active parameter count.
- **Context window**: Larger contexts consume more VRAM. Start with 8192 and
  increase if the model fits comfortably.

With 64GB system RAM:

- Models that slightly exceed VRAM can spill KV cache to RAM (slower but works)
- Set `n-gpu-layers` to a specific number instead of `-1` to control the split

### Step 4: Test the model

```bash
# Quick switch to test a new model
./switch-model.sh <hf-repo> <hf-file>

# Or add it to a preset INI and redeploy
```

### Example: Adding a new model

Say LiveBench shows "NewModel-25B" scoring well. On HuggingFace you find
`unsloth/NewModel-25B-GGUF` with a Q4_K_M file at 14.5 GB.

1. Add a section to the relevant preset INI:

```ini
[unsloth/NewModel-25B-GGUF:Q4_K_M]
c = 16384
```

2. Deploy and test:

```bash
./scripts/pedrogpt/deploy-presets.sh
```

## Preset INI Format

```ini
version = 1

# Global defaults (apply to all models unless overridden)
[*]
c = 8192
n-gpu-layers = -1
jinja = true

# Model-specific section
[hf-org/model-name-GGUF:quantization]
c = 16384                    # Override context size
n-gpu-layers = 40            # Partial offload
load-on-startup = true       # Auto-load when server starts
stop-timeout = 30            # Seconds before force-kill on swap
chat-template = chatml       # Override chat template
model-draft = /path/to.gguf  # Speculative decoding draft model
```

Keys correspond to llama-server CLI args (without leading `--`).
Both short forms (`c`, `ngl`) and env var names (`LLAMA_ARG_N_GPU_LAYERS`) work.
