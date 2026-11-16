# Spark vLLM benchmarks

Two small client-side benchmarks for the vLLM endpoint on the DGX Spark pair
(`spark-f5ea`). They need only the Python 3 standard library.

**Why not `scripts/pedrogpt/benchmark`?** That tool reads llama.cpp's `timings`
object from the response. vLLM does not send one, so against the Spark it
reports zeros. These scripts time the token stream on the client instead.

| Script | Measures | How |
|---|---|---|
| `decode_bench.py` | Single-stream decode tok/s and TTFT | One fixed prompt, 1 warm-up, then 6 runs of `max_tokens=400`. Decode tok/s = `(completion_tokens - 1) / (time after the first token)`. |
| `prefill_bench.py` | Prefill tok/s at four prompt sizes | Unique random prompts (so the prefix cache cannot help), `max_tokens=8`, 2 runs per size. Prefill tok/s = `prompt_tokens / TTFT`. |

## Run

```bash
cd scripts/spark-vllm-bench
python3 decode_bench.py
python3 prefill_bench.py
```

Defaults: `http://spark-f5ea:8000/v1/chat/completions` (MagicDNS, so run from a
tailnet client) and `nvidia/GLM-5.3-Flash-FP4-Local`. Override with:

```bash
SPARK_URL=http://spark-f5ea:8000/v1/chat/completions \
SPARK_MODEL=nvidia/GLM-5.3-Flash-FP4-Local python3 decode_bench.py
```

## Reading the numbers

- **They are a lower bound.** Other clients (workers, evals) may share the
  cluster during a run, and the scripts cannot see that. Check
  `vllm:num_requests_running` on `/metrics` before and after if you need a clean
  number.
- **Reasoning tokens count.** GLM streams reasoning as `reasoning` /
  `reasoning_content`. Both scripts treat the first reasoning or content delta as
  the first token, and `completion_tokens` from the usage chunk includes
  reasoning.
- **The first prefill sizes include warm-up.** The first requests after a restart
  pay Triton JIT compilation, so the smaller sizes read low on a fresh server.
- **Prompt size is set in words, not tokens.** `prefill_bench.py` asks for
  800 / 2,500 / 6,000 / 12,000 random words; the printed token counts come from
  the server's `usage.prompt_tokens`.
- **TTFT boundary (not verified).** `prefill_bench.py` stops the clock at the
  first delta with non-null content, which includes an empty role chunk. If a
  server sent that chunk before prefill finished, prefill tok/s would read high.

Results and their context (model, MTP settings, date) are recorded in
`docs/spark-vllm-troubleshooting.md`.
