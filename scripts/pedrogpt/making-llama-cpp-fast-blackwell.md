# Upgrading llama.cpp to Multi-Token Prediction (MTP) — and what MTP actually is

We run a local inference box, **pedrogpt** — an NVIDIA RTX 5090 (32 GB VRAM, Blackwell) with
64 GB of system RAM, reached over Tailscale — serving an OpenAI-compatible `llama-server` to a
handful of bots and agents. This post is about upgrading it to **Multi-Token Prediction (MTP)**: what
MTP is, why it makes generation faster for free, and exactly how we switched our server over to the
unsloth `Qwen3.6-27B-MTP-GGUF` model.

It ended at **~83 tokens/second** — but it started at ~11, and most of *that* gap turned out to be a
mis-built CUDA backend, not MTP. So there are really two parts here:

1. **What MTP is and how to turn it on** (the main event).
2. **The Blackwell build prerequisite** — because MTP can't help if your CUDA build is quietly
   falling back to a slow path, which ours was.

We'll take MTP first, then the build, then the flags and the numbers — with the *why* behind each.

---

## Part 1: What MTP is, and how we turned it on

### The idea

Normally an LLM generates **one token per forward pass** — a strictly sequential loop, and that
sequential dependency is what makes generation feel slow. **Multi-Token Prediction** breaks the loop
with *self-speculative decoding*:

- The checkpoint ships with a small extra **draft head** that, given the current state, **proposes the
  next few tokens** cheaply.
- The full model then **verifies all of those proposed tokens in a single parallel forward pass**.
- Every proposed token that matches what the full model would have produced is **kept**; the first
  mismatch and everything after it is **thrown away** and regenerated normally.

Because rejected drafts are discarded, the output is **mathematically identical** to ordinary
decoding — same text, same distribution. You are not trading quality for speed. You're just letting
the model commit several tokens per step when it's confident, instead of one at a time.

The "draft model" here isn't a separate model — it's a head baked **into the same GGUF**, so unlike
classic speculative decoding there's **no second model to download, load, or keep in sync**. That's
what makes it a near-free upgrade: swap the model file, add two flags.

How much faster depends on the **acceptance rate** — how often the draft guesses right. Predictable
text (code, structured output) accepts more; on our mixed workload we saw ~50% acceptance and a solid
speedup. Published numbers land around **1.4–2.2x**.

### The one real constraint

**MTP currently requires a single request stream (`--parallel 1`).** It can't be combined with
multi-slot continuous batching, so it's ideal for a single-user-at-a-time box and not (yet) for a
high-concurrency multi-tenant server. For pedrogpt — one model, serving a handful of bots
sequentially — that's no cost at all, so we dedicated the box to a single MTP model.

### Turning it on

1. **Get an MTP build of llama.cpp.** MTP for Qwen3.6 landed in
   [PR #22673](https://github.com/ggml-org/llama.cpp/pull/22673); you need master at/after it. Confirm
   your binary has it and check the exact flag spelling:
   ```bash
   llama-server --help | grep -i spec
   # ours listed:  --spec-type none,draft-simple,draft-eagle3,draft-mtp,ngram-...
   ```
2. **Download an MTP GGUF.** We used
   [`unsloth/Qwen3.6-27B-MTP-GGUF`](https://huggingface.co/unsloth/Qwen3.6-27B-MTP-GGUF) at UD-Q4_K_XL
   (~17 GB — note the file is named `Qwen3.6-27B-UD-Q4_K_XL.gguf`; the MTP head is inside it):
   ```bash
   hf download unsloth/Qwen3.6-27B-MTP-GGUF --include "*UD-Q4_K_XL*" \
     --local-dir /opt/models/qwen3.6-27b-mtp
   ```
3. **Add the two flags** (start at 2, try 3; higher only helps while acceptance stays high):
   ```
   --spec-type draft-mtp --spec-draft-n-max 3
   ```

When it's working you'll see the draft context initialize in the logs:

```
srv  load_model: [spec] estimated memory usage of MTP context is 520.03 MiB
common_speculative_impl_draft_mtp: adding speculative implementation 'draft-mtp'
common_speculative_impl_draft_mtp: - n_max=3, n_min=0, p_min=0.00, n_embd=5120
srv  load_model: speculative decoding context initialized
srv  server is listening on http://0.0.0.0:8000
```

### The gotcha that cost us: `--embeddings` is incompatible with the MTP graph

Our old server ran `--embeddings --pooling mean` so it could double as an embedding endpoint. With the
MTP model that **crash-loops on load**:

```
llama-graph.cpp: GGML_ASSERT(inp != nullptr && "missing result_norm/result_embd tensor") failed
llama-server.service: Failed with result 'core-dump'
```

The embeddings output graph can't be built alongside the MTP spec-decoding graph. The fix is to make
the box **chat-only** and move embeddings to a separate process/model. Drop `--embeddings`/`--pooling`
and it loads clean. (Our launcher now makes embeddings strictly opt-in so this can't sneak back in.)

---

## Part 2: The build prerequisite — a mis-built backend was the real bottleneck

Here's the honest part. Before MTP, this box generated at ~11 tok/s — and MTP is a ~1.4–2.2x lever,
nowhere near enough to explain that. The real culprit was the CUDA build. `llama-server` started fine,
loaded the model, answered requests — nothing *looked* broken. But 11 tok/s on a 5090 for a 4-bit 27B
is absurd; this card should be several times faster. When inference is mysteriously slow and nothing
errors, the CUDA backend is almost always mis-built. Three traps, in the order they bit us — plus a
driver one:

> **The driver trap that started it all.** Before any of these, `nvidia-smi` itself failed with
> `Driver/library version mismatch` — the loaded kernel module (580.126) didn't match the upgraded
> userspace (580.167) after an unattended driver upgrade. In that state CUDA can't initialize and work
> effectively falls off the GPU. A `modprobe -r nvidia... && modprobe nvidia` (no reinstall) fixed it.
> If `nvidia-smi` won't even talk to the card, fix that *first* — nothing else matters until it does.

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

**A correct build alone took us from ~11 tok/s into the high double digits**, before MTP did anything.
If you take one thing from this post: on a new GPU, *suspect the build first*.

---

## Part 3: The flags that matter (and why)

Here's the full tuned launch for a dense 27B on a 32 GB 5090, with the reasoning for each flag:

```bash
llama-server \
  -m /opt/models/qwen3.6-27b-mtp/Qwen3.6-27B-MTP-UD-Q4_K_XL.gguf \
  --alias qwen3.6-27b-mtp --host 0.0.0.0 --port 8000 \
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

Measured on pedrogpt (RTX 5090, 32 GB) via the Go harness — 10 requests, 256 max tokens,
short prompt, generation t/s from llama.cpp's own `timings`:

| Stage | Build | Model | Gen tok/s | Notes |
|-------|-------|-------|-----------|-------|
| Before | broken (driver NVML mismatch + sm_89/suspect CUDA) | Qwen3.6-27B Q4_K_S | ~11 | effectively falling back off the GPU |
| After | sm_120 + CUDA 12.8 + MMQ, MTP | Qwen3.6-27B-MTP UD-Q4_K_XL | **82.7 median** (75.7–87.5) | + `--spec-type draft-mtp` |

**~7.5x faster.** Supporting numbers from the "after" run: prompt eval 107.5 t/s, TTFT p50
168.8 ms, total-latency p50 1.08 s, and **MTP draft acceptance ~50.7% median**. VRAM at runtime:
~20.4 GB of 32 GB used (Q4 weights + ~520 MiB MTP draft context + q8_0 KV for 65K ctx), fully on GPU.

Two honest caveats:
- **We can't cleanly split build-vs-MTP from these two rows.** The "before" box was in a driver NVML
  mismatch that effectively kept work off the GPU, so the bulk of the 7.5x is the build fix — MTP is a
  ~1.4–2.2x layer on top of an already-healthy build, not the source of the order-of-magnitude jump.
  We didn't capture a "fixed build, MTP off" baseline before retiring the old model, so treat the
  split as "mostly build, MTP on top" rather than a precise attribution. (To measure it yourself: run
  the same MTP model with `--spec-type` removed on a scratch port and diff the gen t/s.)
- 50.7% draft acceptance is moderate (some workloads hit ~75%), so there's likely more headroom in
  `--spec-draft-n-max` tuning and prompt characteristics.

---

## Takeaways

1. **MTP is a genuinely free speedup** for single-stream serving: same outputs (drafts that don't
   match are discarded), ~1.4–2.2x faster, no second model to manage — as long as you can live with
   `--parallel 1`. Enable it with `--spec-type draft-mtp --spec-draft-n-max 3` on an MTP GGUF.
2. **MTP and `--embeddings` don't mix** on this model — the embeddings graph crashes the server on
   load. Make the box chat-only and serve embeddings from a separate process.
3. **On a new GPU, suspect the build (and driver) before the model.** Wrong arch, wrong CUDA major
   version, a stale CMake cache, or an `nvidia-smi` driver mismatch will silently cost you 5x+ and
   never throw a useful error. ~11 tok/s on a 5090 is a backend problem, not a model problem.
4. **Use the CUDA 12.8 toolkit on Blackwell**, not 13.x, until the MMQ-kernel regression is resolved.
   Build for `sm_120`, force cuBLAS *off*, and `rm -rf build` before reconfiguring.
5. **Flash attention + quantized KV cache (K=V)** is the combination that buys you long context on a
   32 GB card. Don't offload experts on a dense model that already fits.
6. **Measure with the server's own `timings`.** Client-side wall-clock hides where the time goes;
   `prompt_per_second` / `predicted_per_second` (and draft acceptance) tell the real story.

---

*Sources: [Unsloth MTP docs](https://unsloth.ai/docs/models/mtp),
[Qwen3.6-27B-MTP-GGUF](https://huggingface.co/unsloth/Qwen3.6-27B-MTP-GGUF),
[llama.cpp PR #22673 (MTP)](https://github.com/ggml-org/llama.cpp/pull/22673),
[the Blackwell CUDA-toolkit trap](https://zenn.dev/toki_mwc/articles/rtx5090-blackwell-cuda-toolkit-trap-llama-cpp),
[MXFP4 sm_120 build issue #19662](https://github.com/ggml-org/llama.cpp/issues/19662).*
