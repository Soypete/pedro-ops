# llama.cpp Model Presets

pedrogpt (RTX 5090, sm_120, 32GB VRAM, 64GB RAM) runs **one dedicated tuned model**:
**Qwen3.6-27B with Multi-Token Prediction (MTP)**.

The live server is launched by `/opt/llama.cpp/run-server.sh` from `/etc/llama-server.env`
(installed by `setup-llama-cpp.sh`) — a single-model invocation, **not** router/`--models-preset`
mode. MTP requires a single stream (`parallel = 1`) and cannot coexist with multi-slot batching, so
the box serves exactly one model.

`all-models.ini` in this directory is kept only as a **rollback / reference artifact** describing the
MTP model for router mode; it is not what the running service reads.

> History: this box previously ran a 5-model router (GLM-4.7-Flash, Nemotron-3-Super-120B,
> Qwen3-Next-80B, Qwen2.5-VL-32B, plain Qwen3.6-27B). Those were retired in favor of the single fast
> MTP model. See `git log` and `docs/llama-cpp-build.md` for the rationale.

## The model

| Section | Model | Quant | Type | Notes |
|---------|-------|-------|------|-------|
| `qwen3.6-27b-mtp` | Qwen3.6-27B-MTP | UD-Q4_K_XL (~17.9 GB) | Dense + MTP head | self-speculative decoding, `parallel=1` |

API model id: **`qwen3.6-27b-mtp`** (set via `--alias`). Callers pass it in the `"model"` field.

## Downloading the model

```bash
hf download unsloth/Qwen3.6-27B-MTP-GGUF \
  --include "*UD-Q4_K_XL*" \
  --local-dir /opt/models/qwen3.6-27b-mtp
```

Q5_K_M (~19.8 GB) is the fallback if more quality headroom is wanted — both fit 32GB VRAM alongside
the MTP head and a q8_0 KV cache.

## Tuning reference (set in /etc/llama-server.env)

| Setting | Value | Why |
|---------|-------|-----|
| `-ngl -1` | all layers on GPU | dense 27B fits fully; any CPU layer tanks throughput |
| `-fa on` | flash attention | faster + prerequisite for KV-cache quantization |
| `--cache-type-k/v q8_0` | quantized KV | ~halves KV VRAM; **K and V must match** or attention falls back to a slow path |
| `-ub 1024` | micro-batch | larger ubatch improves prefill; safe on a 5090 |
| `-np 1` | single slot | **required** by MTP |
| `--spec-type draft-mtp --spec-draft-n-max 2` | enable MTP | self-speculative decoding, ~1.4–2.2x, no quality loss |

> Confirm the exact spec-type spelling for your build: `llama-server --help | grep -i spec`.
> Some builds spell it `mtp` rather than `draft-mtp`.

## Finding a future replacement model

1. **Check [LiveBench](https://livebench.ai/#/?highunseenbias=true)** — enable "High Unseen Bias",
   sort by Overall or category.
2. **Find a GGUF on [HuggingFace](https://huggingface.co)** — prefer `unsloth` or `bartowski`. For a
   dense model on 32GB VRAM, `Q4_K_M`/`UD-Q4_K_XL` up to ~30B leaves room for KV cache.
3. **Prefer an MTP GGUF** when available — the built-in draft head gives a free speedup.

| Quant | Quality | Notes |
|-------|---------|-------|
| UD-Q4_K_XL | Excellent | unsloth dynamic 4-bit, recommended |
| Q5_K_M | Very good | more headroom, still fits |
| Q6_K | Excellent | ~22.9 GB, tighter KV budget |
| Q8_0 | Near-lossless | ~29 GB, small context only |
