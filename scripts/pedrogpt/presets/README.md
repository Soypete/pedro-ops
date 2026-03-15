# llama.cpp Model Presets

Model preset configurations for pedrogpt (RTX 5090, 32GB VRAM, 64GB RAM).

## Presets

| Preset | Model | Quant | Type | Use Case |
|--------|-------|-------|------|----------|
| `text.ini` | GPT-OSS 20B | Q4_K_M (11.6 GB) | Dense | General chat, writing, reasoning (default) |
| `text.ini` | Nemotron-3-Super 120B-A12B | UD-Q4_K_XL | MoE (12B active) | Heavy reasoning, tool calling |
| `code.ini` | Qwen3-Next 80B-A3B | UD-Q4_K_XL | MoE (3B active) | Code gen with MoE expert offload |
| `code.ini` | Qwen3-Coder 30B-A3B | Q4_K_M (18.6 GB) | MoE (3B active) | Code gen, fully GPU-resident |
| `vision.ini` | Qwen2.5-VL 32B | Q4_K_M (~18 GB) | Dense | Image understanding, OCR, visual QA |
| `tts.ini` | Qwen2.5-Omni 7B | — | Dense | Text-to-speech (port 8001) |
| `all-models.ini` | All of the above | — | Router | Dynamic switching via API request |

## How It Works

With `--models-preset`, llama-server loads the INI file and registers all
models. You specify which model to use in each API request via the `model`
field. The server dynamically loads/unloads models as needed:

```bash
# Start server with all models registered
llama-server \
  --models-preset ./presets/all-models.ini \
  --models-max 1 \
  --host 0.0.0.0 --port 8080 \
  --metrics --no-webui

# Request a specific model — server loads it on demand
curl http://localhost:8080/v1/chat/completions \
  -d '{"model": "unsloth/gpt-oss-20b-GGUF:Q4_K_M", "messages": [...]}'

# Switch to coding model — server unloads text, loads code
curl http://localhost:8080/v1/chat/completions \
  -d '{"model": "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_M", "messages": [...]}'
```

With `--models-max 1`, only one model stays in memory at a time. The server
swaps when you request a different model in the `model` field.

### Single preset mode

```bash
llama-server \
  --models-preset ./presets/text.ini \
  --host 0.0.0.0 --port 8080 \
  --metrics --no-webui
```

### MoE expert offload (Qwen3-Next 80B)

For large MoE models, offload expert layers to system RAM while keeping
attention on GPU. Add `-ot` to the CLI (not in the INI):

```bash
llama-server \
  --models-preset ./presets/code.ini \
  -ot ".ffn_.*_exps.=CPU" \
  --flash-attn \
  --host 0.0.0.0 --port 8080 \
  --metrics --no-webui
```

### TTS (separate process on port 8001)

```bash
llama-server \
  --models-preset ./presets/tts.ini \
  --host 0.0.0.0 --port 8001 \
  --metrics --no-webui
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

See `deploy-presets.sh` for options (SCP vs Taildrop, preset selection).

## Finding Models

### Step 1: Check LiveBench scores

Go to [LiveBench](https://livebench.ai/#/?highunseenbias=true) to find
top-performing models. Filter by:

1. Click **"High Unseen Bias"** to filter for models tested on unseen data
2. Sort by **Overall** score or by category (Coding, Reasoning, Math, etc.)
3. Look for open-weight models — MoE models with low active params are ideal
4. Note the model name (e.g., "Qwen3-Next-80B-A3B")

### Step 2: Find GGUF quantizations on HuggingFace

Once you've identified a model on LiveBench:

1. Go to [HuggingFace](https://huggingface.co)
2. Search for `<model-name> GGUF` (e.g., "Qwen3-Next-80B-A3B GGUF")
3. Look for repos by **unsloth** or **bartowski** — they provide reliable quantizations
4. For MoE models, prefer **UD-Q4_K_XL** (unsloth dynamic quant) — it applies
   higher precision to important layers automatically
5. Check the quant table for file sizes:

| Quantization | Quality | Notes |
|-------------|---------|-------|
| UD-Q4_K_XL | Excellent | Unsloth dynamic quant, best for MoE |
| UD-Q2_K_XL | Good | Unsloth dynamic 2-bit, smaller |
| Q8_0 | Near-lossless | ~1.1x active params in GB |
| Q6_K | Excellent | ~0.85x active params in GB |
| Q5_K_M | Very good | ~0.73x active params in GB |
| Q4_K_M | Good | ~0.6x active params in GB |

### Step 3: Size your model for pedrogpt

**32GB VRAM:**

- **Dense models**: Up to ~25B at Q4_K_M, ~20B at Q8_0
- **MoE models**: Total params can be 80-120B+ since only active params matter.
  With `-ot ".ffn_.*_exps.=CPU"`, expert layers run from 64GB system RAM while
  attention stays on GPU.
- **Context window**: Larger contexts consume more VRAM. With flash attention
  (`--flash-attn`), you can push to 64K+ on smaller active-param MoE models.

**64GB system RAM:**

- Offload MoE expert layers to RAM: `-ot ".ffn_.*_exps.=CPU"`
- KV cache can spill to RAM for very long contexts
- Set `n-gpu-layers` to a specific number instead of `-1` to control the split

### Step 4: Add to a preset and deploy

1. Add a section to the relevant preset INI:

```ini
[unsloth/NewModel-GGUF:UD-Q4_K_XL]
c = 16384
```

2. Deploy:

```bash
./scripts/pedrogpt/deploy-presets.sh --preset all
```

3. Test via API:

```bash
curl http://pedrogpt:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "unsloth/NewModel-GGUF:UD-Q4_K_XL", "messages": [{"role": "user", "content": "Hello"}]}'
```

## Preset INI Format

```ini
version = 1

# Global defaults (apply to all models unless overridden)
[*]
c = 8192
n-gpu-layers = -1
jinja = true

# Model-specific section — name matches HF repo:quant
[hf-org/model-name-GGUF:quantization]
c = 16384                    # Context size
n-gpu-layers = 99            # GPU layer count (-1 = all)
flash-attn = true            # Flash attention
load-on-startup = true       # Auto-load when server starts
stop-timeout = 30            # Seconds before force-kill on swap
chat-template = chatml       # Override chat template
temp = 0.6                   # Sampling temperature
top-p = 0.95                 # Top-p sampling
model-draft = /path/to.gguf  # Speculative decoding draft model
```

Keys correspond to llama-server CLI args (without leading `--`).
Both short forms (`c`, `ngl`) and env var names (`LLAMA_ARG_N_GPU_LAYERS`) work.

**Note:** Router-level args (`--host`, `--port`, `-ot`) go on the CLI, not in
the INI file. The INI defines per-model settings only.
