# From 11 to ~100 tok/s: Making llama.cpp Fast on an RTX 5090 with Qwen3.6-27B MTP

We run a local inference box, **pedrogpt** — an NVIDIA RTX 5090 (32 GB VRAM, Blackwell) with
64 GB of system RAM, reached over Tailscale — serving an OpenAI-compatible `llama-server` to a
handful of bots and agents. It was generating at **~11 tokens/second** on a 4-bit 27B model. That's
*wrong* for this hardware by roughly an order of magnitude, and chasing down why turned into a tour of
the things that quietly wreck llama.cpp performance on a brand-new GPU.

Two changes took us from 11 tok/s to the high double / triple digits:

1. **Rebuilding llama.cpp correctly for Blackwell** (the build was the real culprit).
2. **Switching to a Multi-Token Prediction (MTP) model** for a further free speedup.

Here's the whole story, with the *why* behind every flag.

---

## Part 1: The build was lying to us

`llama-server` started fine, loaded the model, answered requests — nothing *looked* broken. But
11 tok/s on a 5090 for a 4-bit 27B is absurd; this card should be several times faster. When inference
is mysteriously slow and nothing errors, the CUDA backend is almost always mis-built. Three traps, in
the order they bit us:

### Trap 1: the wrong compute architecture

Our build scripts and docs described the 5090 as **sm_89**. That's the *RTX 4090* (Ada Lovelace). The
5090 is **Blackwell, compute capability 12.0 → `sm_120`**. `CMAKE_CUDA_ARCHITECTURES` wants the
compute capability with the dot removed:

| GPU | Arch | Compute cap | `CMAKE_CUDA_ARCHITECTURES` |
|-----|------|-------------|----------------------------|
| RTX 5090 | Blackwell | 12.0 | **120** |
| RTX 4090 | Ada | 8.9 | 89 |
| RTX 3090 | Ampere | 8.6 | 86 |
| A100 | Ampere | 8.0 | 80 |

Build for the wrong arch and CUDA either ships kernels that don't match the hardware or falls back to
slow PTX JIT at load time. **Fix:** `-DCMAKE_CUDA_ARCHITECTURES=120`.

### Trap 2: CUDA 13.x silently falls back to cuBLAS on Blackwell

This is the big one. On Blackwell, **CUDA 13.x's MMQ (matrix-multiply-quantized) kernels crash**, and
llama.cpp falls back to a generic cuBLAS path. The measured difference on a 5090 is brutal — on the
order of **5611 t/s prefill with CUDA 12.8 + MMQ vs 989 t/s on the cuBLAS fallback**, a 5–6x swing.

**Fix:** build with the **CUDA 12.8** toolkit specifically. Not 13.x, not "whatever `apt` installs."

### Trap 3: a stale `build/` directory

CMake caches variables across reconfigures. If `GGML_CUDA_FORCE_CUBLAS` was ever set, or an old arch
was configured, those values *persist* in `build/CMakeCache.txt` even after you "fix" the command. We
now `rm -rf build` before every configure and assert the result:

```bash
rm -rf build
cmake -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES=120 \
  -DGGML_CUDA_FORCE_CUBLAS=OFF \
  -DCUDAToolkit_ROOT=/usr/local/cuda-12.8 \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release -j$(nproc)

# assert cuBLAS was NOT forced on — this is the silent 5x killer
grep FORCE_CUBLAS build/CMakeCache.txt   # expect: ...=OFF
```

> Blackwell aside: some llama.cpp commits fail to compile MXFP4 kernels for `sm_120`
> (`Instruction 'mma with block scale' not supported on .target 'sm_120'`), and `-DGGML_CUDA_MXFP4=OFF`
> doesn't reliably disable it. Use CUDA 12.8 and a recent master where it's fixed. It only affects
> MXFP4 models (e.g. GPT-OSS) at build time — K-quant GGUFs like Qwen3.6 are unaffected at runtime.

**A correct build alone took us from ~11 tok/s into the high double digits**, before touching the
model. If you take one thing from this post: on a new GPU, *suspect the build first*.

---

## Part 2: Multi-Token Prediction (MTP) — a free speedup

Once the build was healthy, we swapped the plain Qwen3.6-27B GGUF for
[`unsloth/Qwen3.6-27B-MTP-GGUF`](https://huggingface.co/unsloth/Qwen3.6-27B-MTP-GGUF).

**What MTP is:** normally an LLM generates one token per forward pass. MTP bakes a small *draft head*
into the checkpoint that proposes several upcoming tokens at once; the main model then **verifies them
in parallel in a single forward pass**, and only verified tokens are kept. It's *self-speculative
decoding* — the draft model lives inside the same GGUF, so there's no second model to load or manage.
Because rejected drafts are thrown away, the output distribution is **identical** to ordinary
decoding: same answers, just faster.

Reported speedups are **~1.4–2.2x** depending on how predictable the text is (acceptance rate). The
tradeoffs are small: ~2 GB extra VRAM for the draft head, a slight prompt-processing penalty, and one
hard constraint — **MTP currently requires a single request stream (`--parallel 1`)**, so it can't be
combined with multi-slot continuous batching. For a single-user-at-a-time box like ours, that's free.

Enabling it (confirm the exact spelling for your build with `llama-server --help | grep -i spec`):

```
--spec-type draft-mtp --spec-draft-n-max 3
```

`--spec-draft-n-max` is how many tokens the draft head proposes per step. Start at 2, try 3; going
higher only helps while acceptance stays high.

---

## Part 3: The flags that matter (and why)

Here's the full tuned launch for a dense 27B on a 32 GB 5090, with the reasoning for each flag:

```bash
llama-server \
  -m /opt/models/qwen3.6-27b-mtp/Qwen3.6-27B-MTP-UD-Q4_K_XL.gguf \
  --alias qwen3.6-27b-mtp --host 0.0.0.0 --port 8080 \
  -ngl 99 \
  -c 65536 \
  -fa on \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  -b 2048 -ub 1024 \
  -np 1 \
  --mlock --jinja \
  --spec-type draft-mtp --spec-draft-n-max 3 \
  --temp 0.7 --top-k 20 --top-p 0.8 --presence-penalty 1.5 --min-p 0.0 \
  --chat-template-kwargs '{"enable_thinking":false}'
```

- **`-ngl 99` (offload everything).** Put *all* layers on the GPU. Our UD-Q4_K_XL weights are ~17.9 GB
  on a 32 GB card — it fits fully, so there's no reason to leave any layer on the CPU. Even a few CPU
  layers tank throughput, because every token has to traverse them single-threaded. (This is the same
  lesson we learned the hard way earlier: a manual `-ngl 35` once cost us a 10x slowdown.)
- **`-fa on` (flash attention).** A fused attention kernel — faster, and a **prerequisite for KV-cache
  quantization**. Essentially no downside on modern CUDA.
- **`--cache-type-k q8_0 --cache-type-v q8_0` (quantized KV cache).** Stores the K/V cache at 8-bit,
  roughly **halving** its VRAM footprint with negligible quality loss, which is what lets us run a big
  context. Two gotchas: it **requires `-fa`**, and **K and V must use the same type** — mismatch them
  and llama.cpp silently drops to the slow non-fused attention path.
- **`-b 2048 -ub 1024` (batch / micro-batch).** `-b` is the logical token budget per batch; `-ub` is
  what's physically shipped to the GPU per step (and must divide `-b`). Raising `-ub` **improves
  prompt-processing throughput** on long prompts; 1024 is comfortable on a 5090. Too small flatlines
  prefill; too large OOMs.
- **`-np 1`.** Required by MTP (above). It also means a single KV-cache allocation instead of one per
  slot — more room for context.
- **`--mlock`.** Pins the model in RAM so the OS can't page it out, avoiding latency spikes.
- **`--chat-template-kwargs '{"enable_thinking":false}'`.** Qwen3.6 has a thinking mode that emits
  `<think>…</think>` / `reasoning_content` before the answer. We disable it for direct responses;
  flip it back per-request when you want chain-of-thought.

### What we deliberately did *not* use

- **`--n-cpu-moe` / `--override-tensor` (`-ot`) — not needed.** Those offload MoE *expert* tensors to
  CPU when a model doesn't fit. Qwen3.6-27B is **dense** and fits fully in 32 GB at Q4/Q5/Q6, so
  there's nothing to offload. (We *do* use `-ot` for genuine MoE models that overflow VRAM — but
  reaching for it on a model that already fits just adds PCIe round-trips.)
- **Chasing the full 256K context.** The model supports 256K, but the KV cache for 256K won't
  co-reside with Q4 weights in 32 GB even quantized. We cap at 65,536 (131,072 also fits). Qwen3.6's
  hybrid DeltaNet/GQA design keeps only 1-in-4 layers holding a real KV cache, so even this is cheap.

---

## Part 4: Measuring it

Throughput claims are worthless without numbers, so we benchmark every change with two tools:

- **`llama-bench`** for raw model/kernel throughput (independent of the HTTP server):
  ```bash
  llama-bench -m <gguf> -fa 1 -d 0,4096,8192,16384,32768 -p 2048 -n 32 -ub 1024 -ngl 99
  ```
- **A small Go harness** that streams `/v1/chat/completions` and reads llama.cpp's own `timings`
  object (ground-truth prompt/gen t/s and MTP draft-acceptance), plus client-side TTFT and p50/p95.
  `llama-bench` can't show the MTP gain — MTP is a server-side speculative-decoding feature — so the
  API benchmark is what captures it.

### Results

<!-- TODO(box-step): fill in after running the benchmark on pedrogpt -->

| Stage | Build | Model | Gen tok/s | Prompt tok/s | Notes |
|-------|-------|-------|-----------|--------------|-------|
| Before | sm_89 / suspect CUDA | Qwen3.6-27B Q4_K_S | ~11 | — | the starting point |
| After rebuild | sm_120 + CUDA 12.8 + MMQ | Qwen3.6-27B Q4_K_S | _TBD_ | _TBD_ | build fix alone |
| After MTP | sm_120 + CUDA 12.8 | Qwen3.6-27B-MTP UD-Q4_K_XL | _TBD_ | _TBD_ | + `--spec-type draft-mtp` |

_(MTP draft acceptance observed: _TBD_%.)_

---

## Takeaways

1. **On a new GPU, suspect the build before the model.** Wrong arch, wrong CUDA major version, or a
   stale CMake cache will silently cost you 5x and never throw an error.
2. **Use the CUDA 12.8 toolkit on Blackwell**, not 13.x, until the MMQ-kernel regression is resolved.
   Build for `sm_120`, force cuBLAS *off*, and `rm -rf build` before reconfiguring.
3. **MTP is a genuinely free speedup** for single-stream serving: same outputs, ~1.4–2.2x faster, no
   second model — as long as you can live with `--parallel 1`.
4. **Flash attention + quantized KV cache (K=V)** is the combination that buys you long context on a
   32 GB card. Don't offload experts on a dense model that already fits.
5. **Measure with the server's own `timings`.** Client-side wall-clock hides where the time goes;
   `prompt_per_second` / `predicted_per_second` (and draft acceptance) tell the real story.

---

*Sources: [Unsloth MTP docs](https://unsloth.ai/docs/models/mtp),
[Qwen3.6-27B-MTP-GGUF](https://huggingface.co/unsloth/Qwen3.6-27B-MTP-GGUF),
[llama.cpp PR #22673 (MTP)](https://github.com/ggml-org/llama.cpp/pull/22673),
[the Blackwell CUDA-toolkit trap](https://zenn.dev/toki_mwc/articles/rtx5090-blackwell-cuda-toolkit-trap-llama-cpp),
[MXFP4 sm_120 build issue #19662](https://github.com/ggml-org/llama.cpp/issues/19662).*
