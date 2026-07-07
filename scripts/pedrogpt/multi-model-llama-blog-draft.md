> **Historical note (June 2026):** this post describes the previous *multi-model router* setup on
> pedrogpt. The box has since been dedicated to a single tuned model (Qwen3.6-27B with MTP) for
> maximum speed — see `making-llama-cpp-fast-blackwell.md` for the current architecture and the
> Blackwell build/perf lessons. This draft is kept as a record of the router approach.

# From One Model to Many: Running a Multi-Model LLM Router on an RTX 5090 with llama.cpp and systemd

We recently upgraded our local AI inference setup on pedrogpt — a machine with an NVIDIA RTX 5090 (32GB VRAM) and 64GB of system RAM — from running a single hardcoded model to a full multi-model router. Five models, one server process, zero restarts to switch between them. Here's how we did it.

---

## The Old Setup

The original `llama-server` service was simple: one model, loaded at startup, served forever.

```ini
[Service]
EnvironmentFile=/etc/llama-server.env
ExecStart=/opt/llama.cpp/build/bin/llama-server \
    --host 0.0.0.0 \
    --port 8080 \
    --hf-repo unsloth/gpt-oss-20b-GGUF \
    --hf-file gpt-oss-20b-Q4_K_M.gguf \
    --ctx-size 8192 \
    --n-gpu-layers -1 \
    --parallel 4 \
    --jinja --no-webui --metrics
```

To switch models you'd update `/etc/llama-server.env`, restart the service, wait for the model to load, and hope nothing was mid-inference. It worked, but it wasn't flexible enough for a multi-purpose assistant — you want a coding model for code, a reasoning model for analysis, a vision model for images.

---

## The New Setup: `--models-preset`

llama.cpp added a `--models-preset` flag that lets you define a roster of models in an INI file. The server registers all of them at startup but only loads one at a time into VRAM. Callers switch models by setting `"model"` in the API request — the same field as the OpenAI API. The server handles the swap automatically (~30 seconds to unload the current model and load the next one).

### The model roster (`all-models.ini`)

```ini
version = 1

[*]
n-gpu-layers = -1
ctx-size = 8192
jinja = true
stop-timeout = 30

[gpt-oss-20b]
model = /opt/models/gpt-oss-20b/gpt-oss-20b-Q4_K_M.gguf
ctx-size = 16384
load-on-startup = true

[nemotron-3-super-120b]
model = /opt/models/nemotron-3-super-120b/UD-Q4_K_XL/NVIDIA-Nemotron-3-Super-120B-A12B-UD-Q4_K_XL-00001-of-00003.gguf
ctx-size = 16384
temp = 0.6
top-p = 0.95

[qwen3-next-80b]
model = /opt/models/qwen3-next-80b/Qwen3-Next-80B-A3B-Instruct-UD-Q4_K_XL.gguf
n-gpu-layers = 99
ctx-size = 65536
flash-attn = true

[qwen3-coder-30b]
model = /opt/models/qwen3-coder-30b/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf
ctx-size = 32768

[qwen2.5-vl-32b]
model = /opt/models/qwen2.5-vl-32b/qwen2.5-vl-32b-instruct-q4_k_m.gguf
ctx-size = 8192
```

Each section name (e.g. `gpt-oss-20b`) is the model identifier callers use in API requests. The `[*]` section sets defaults for all models. `load-on-startup = true` on the default model means it's hot in VRAM immediately after the service starts.

### The new systemd drop-in

Rather than touching the base `llama-server.service` file, we use a drop-in override at `/etc/systemd/system/llama-server.service.d/preset.conf`. This keeps the base unit clean and makes rollback trivial.

```ini
[Service]
ExecStart=
ExecStart=/opt/llama.cpp/build/bin/llama-server \
    --host 0.0.0.0 \
    --port ${PORT} \
    --models-preset /opt/llama.cpp/presets/all-models.ini \
    --models-max 1 \
    --parallel ${N_PARALLEL} \
    --jinja \
    --no-webui \
    --metrics \
    -ot ".ffn_.*_exps.=CPU" \
    --flash-attn on
```

The first blank `ExecStart=` clears the original command before setting the new one — that's how systemd drop-ins work. `${PORT}` and `${N_PARALLEL}` come from the existing `/etc/llama-server.env`.

---

## MoE Models and Hardware Config: The Interesting Part

Three of our five models are Mixture-of-Experts (MoE) architectures. MoE models have a large total parameter count but only activate a fraction of those parameters per forward pass. This is what makes them practical on consumer hardware.

### How MoE fits our hardware

| Model | Total params | Active params | GGUF size | Strategy |
|-------|-------------|---------------|-----------|----------|
| GPT-OSS 20B | 20B (dense) | 20B | 11 GB | All GPU |
| Nemotron-3-Super 120B-A12B | 120B | 12B | ~79 GB | GPU attn + RAM experts |
| Qwen3-Next 80B-A3B | 80B | 3B | ~43 GB | GPU attn + RAM experts |
| Qwen3-Coder 30B-A3B | 30B | 3B | 18 GB | All GPU |
| Qwen2.5-VL 32B | 32B (dense) | 32B | 19 GB | All GPU |

The RTX 5090 has 32GB of VRAM. The two large MoE models (Nemotron 120B and Qwen3-Next 80B) can't fit their full weight files in VRAM — but they don't need to. In MoE, the FFN expert layers are the large weight matrices that are only partially activated. We can offload those to the 64GB of system RAM and keep everything else on the GPU.

### Tensor offloading with `-ot`

llama.cpp's `-ot` flag lets you route specific tensor patterns to a device. We use:

```
-ot ".ffn_.*_exps.=CPU"
```

This regex matches all FFN expert weight tensors (`ffn_gate_exps`, `ffn_down_exps`, `ffn_up_exps`, etc.) and sends them to CPU/RAM. The attention layers, embeddings, and active expert routing stay on the RTX 5090. During inference, the GPU fetches only the expert weights it needs for each token via PCIe — not the entire weight file.

Combined with `--flash-attn on`, which reduces KV cache memory pressure during long-context inference, this lets us run a 120B-parameter model on a single consumer GPU with 32GB VRAM.

### Multi-part GGUFs

Nemotron-3-Super came as a 3-file GGUF set (`*-00001-of-00003.gguf`, etc.) totaling ~79GB. llama.cpp handles multi-part GGUFs natively — you point it at the first file and it reads the rest automatically. The INI just references `*-00001-of-00003.gguf`.

---

## Switching Models

From the caller's perspective, switching models is one field in the JSON body:

```bash
# Default: general reasoning
curl http://pedrogpt:8080/v1/chat/completions \
  -d '{"model": "gpt-oss-20b", "messages": [...]}'

# Code generation
curl http://pedrogpt:8080/v1/chat/completions \
  -d '{"model": "qwen3-coder-30b", "messages": [...]}'

# Heavy reasoning with a 120B MoE
curl http://pedrogpt:8080/v1/chat/completions \
  -d '{"model": "nemotron-3-super-120b", "messages": [...]}'
```

The server sees the `model` field, checks if that model is loaded, unloads the current one if not, loads the requested model, and processes the request. The `--models-max 1` flag enforces that only one model occupies VRAM at a time.

---

## Deployment

We manage this with a deploy script that:

1. SCPs the INI files to `/opt/llama.cpp/presets/` on pedrogpt
2. Writes the systemd drop-in via `sudo tee`
3. Runs `systemctl daemon-reload && systemctl restart llama-server`

Models are pre-downloaded to `/opt/models/` using `huggingface-cli` with `--local-dir` — no HuggingFace streaming at runtime. This means startup is fast (no download wait) and the service works without internet access.

---

## What Changed for Callers

The API is OpenAI-compatible. The only change clients need is setting the `"model"` field to the section name from the INI (e.g. `gpt-oss-20b` instead of `unsloth/gpt-oss-20b-GGUF`). Everything else — endpoint, request format, response format — stays the same.

---

## Results

Five models, one port, one process. The RTX 5090's 32GB VRAM comfortably holds any of the dense models outright, and with expert offloading to RAM, even a 120B MoE becomes practical. Model swap latency is ~30 seconds — acceptable for task-switching workloads where you're not hot-swapping mid-conversation.

The llama.cpp `--models-preset` feature does the heavy lifting. The systemd drop-in keeps the operational config clean and rollback to single-model mode is one `rm` and a restart.

---

## Addendum: Context Windows, Quantization, and What We Learned the Hard Way

After the initial deployment, we iterated on context window sizes and quantization choices. Here's what we found.

### Bumping Context Windows

The original preset used conservative `ctx-size` values (8192–16384). We bumped these to match each model's actual training context length:

| Model | Old ctx-size | New ctx-size | Model max |
|-------|-------------|-------------|-----------|
| gpt-oss-20b | 16,384 | 32,768 | 32,768 |
| nemotron-3-super-120b | 16,384 | 131,072 | 1,048,576 |
| qwen3-next-80b | 65,536 | 131,072 | 131,072 |
| qwen3-coder-30b | 32,768 | 131,072 | 131,072 |
| qwen2.5-vl-32b | 8,192 | 32,768 | 32,768 |

One gotcha: the preset INI files live in the repo but the *running* server uses the copy deployed to `/opt/llama.cpp/presets/`. Updating the repo without redeploying means the server keeps serving the old config. The `/v1/models` endpoint shows the active `ctx-size` per model — always check there, not the repo.

### Per-Model Overrides vs CLI Flags

Our initial setup passed `-ot ".ffn_.*_exps.=CPU" --flash-attn on` on the CLI, which applied globally to every model. This works but is a blunt instrument — dense models like gpt-oss-20b don't need expert offloading, and the global `--parallel` flag forced the same slot count on every model.

The better approach is per-model configuration in the INI:

```ini
[nemotron-3-super-120b]
override-tensor = .ffn_.*_exps.=CPU
flash-attn = true
no-mmap = true
parallel = 1
```

This lets each model define its own offload strategy, parallelism, and memory settings. The CLI-level flags are reserved for things that truly apply to every model (like `--jinja` and `--metrics`).

### The Quantization Trap: Q4_K_XL vs Q3_K_M for MoE

We originally used the `UD-Q4_K_XL` quant for Nemotron-3-Super-120B (~77 GB across 3 GGUF files). With all experts offloaded to CPU, it loaded and ran at ~4.3 tokens/second generation speed — usable but slow.

We tried to speed it up with selective expert offloading: keep layers 0–14 on GPU and offload only layers 15+ to CPU. The idea was to reduce the number of CPU↔GPU round-trips per token. It failed — llama.cpp tried to allocate a single ~79 GB CUDA buffer for the retained expert layers and OOM'd immediately. Even keeping just layers 0–4 on GPU triggered the same allocation. The expert tensors in this model are too large for partial offloading on 32 GB VRAM.

We switched to `Q3_K_M` (~52 GB, single file). The tradeoffs:

- **RAM headroom**: 52 GB in RAM vs 77 GB leaves more room for the OS, KV cache, and other processes
- **Quality**: Slightly lower fidelity than Q4_K_XL, but for a 120B MoE with only 12B active params, the per-expert quality loss is less impactful than it would be for a dense model
- **Speed**: Same generation speed (~4–5 tok/s) since the bottleneck is CPU expert inference over PCIe, not quantization level
- **Single file**: No multi-part GGUF complexity

### Performance Tuning for MoE on CPU+GPU

For MoE models with expert offloading, we found these settings matter:

- **`no-mmap = true`**: llama.cpp itself recommends this when using tensor overrides to CPU. With mmap, the OS page cache competes with the model for RAM. Without mmap, the model loads into a dedicated allocation.
- **`parallel = 1`**: Each parallel slot reserves its own KV cache in VRAM. For a 131K context window, 4 slots × 131K tokens is a huge KV footprint. Dropping to 1 slot freed significant VRAM. For a model that's already slow at ~4 tok/s, concurrent request handling isn't the bottleneck.
- **`flash-attn = true`**: Reduces KV cache memory pressure, critical at 131K context lengths.

### The Deploy Script Problem

Our `deploy-presets.sh` script uses SSH to copy files and restart the service remotely. In practice, `ssh -t` with `sudo` prompts is fragile from non-interactive scripts — heredocs conflict with terminal allocation, and password prompts fail silently. The workaround:

1. SCP the preset files to `/tmp/` on the remote (no sudo needed)
2. SSH in interactively to move files and restart the service

Long-term fix: passwordless sudo for the specific `systemctl` and `cp` commands the deploy script needs, via a sudoers rule on pedrogpt.
