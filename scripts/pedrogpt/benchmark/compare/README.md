# TTFT comparison harness

Measures **client-observed time-to-first-token** across two or more OpenAI-compatible
backends, using identical prompts and one stopwatch.

```bash
go run ./compare \
  -a http://pedrogpt:8000/v1,qwen3.8-27b,pedrogpt/qwen3.8-27b \
  -b http://100.87.122.109:8000/v1,QuantTrio/MiniMax-M2.5-AWQ,spark/MiniMax-M2.5 \
  -n 10
```

Backends are `URL,MODEL[,LABEL]`, repeatable via `-backend`.

## Why client-side rather than Prometheus

Server metrics cannot compare these two backends fairly:

- **vLLM** exposes a true TTFT histogram, but its prefill-derived *throughput* is
  inflated — `request_prefill_time_seconds` is wall-clock per request while vLLM
  prefills many requests concurrently, so summing it undercounts compute time.
- **llama.cpp** exposes **no TTFT metric at all**, only cumulative counters. Any TTFT
  figure for it has to be modelled from prefill throughput.

Measuring from the client sidesteps both: same prompt, same clock, and it captures what
a user actually waits for in opencode.

## Field-name gotcha

Thinking models stream reasoning before the answer, and the servers spell it
differently:

| Server | Field |
|---|---|
| llama.cpp | `reasoning_content` |
| vLLM | `reasoning` |

The tool decodes **both**. Handling only one makes every chunk look empty and the
backend appear to return nothing — which is exactly what happened on the first run
here. If you add a third backend and it reports "no content received", check this first.

Both servers also omit the `usage` block from a stream unless asked, so the request
sets `stream_options.include_usage` — without it, generated-token counts and tok/s
read zero.

## Reading the results

```
=== TTFT (client-measured: network + queue + prefill) ===
backend                               n    p50 ms    p95 ms   mean ms    tok/s
pedrogpt/qwen3.8-27b                  5      59.5     155.5      83.6     75.3
spark/MiniMax-M2.5                    5      49.1      50.7      49.4     27.3
```

**TTFT is load-dependent — do not quote a single run.** Two runs minutes apart gave
opposite verdicts:

| Run | pedrogpt p50 | Spark p50 | Spark p95 | verdict |
|---|---|---|---|---|
| Spark busy | 59.7 ms | 144.7 ms | 442.3 ms | pedrogpt 2.42x faster |
| Spark idle | 59.5 ms | 49.1 ms | 50.7 ms | Spark 1.21x faster |

pedrogpt was steady at ~59 ms both times; Spark swung between 49 ms and 145 ms
depending on concurrent traffic. That is a real property of a shared batching server
versus a single-stream box, not measurement noise — but it means any TTFT claim needs
the load conditions stated. Run repeatedly, at different times, and report the spread.

**Generation throughput is the stable comparison.** The harness and Prometheus agree
independently:

| Backend | tok/s (harness) | tok/s (Prometheus) |
|---|---|---|
| pedrogpt/qwen3.8-27b | 75.3 | 75.8 |
| spark/MiniMax-M2.5 | 27.3 | 18.5 |

## Caveats

- TTFT here is the **full** client-observed delay — network (Tailscale), queueing,
  scheduling and prefill. Honest as a user-facing number, but a slower result does not
  necessarily mean slower prefill.
- Comparing a reasoning model against a non-reasoning one is not apples-to-apples
  however TTFT is measured. Both models here reason by default.
- pedrogpt runs a router with `--models-max 1`. If the requested model is not resident,
  the first request pays a ~18 GB load; `-warmup` (default) discards it, but that
  warmup request itself can take minutes.
- `-interleave` (default) rotates backends per round so load drift affects both
  equally. Turn it off only if you want strictly sequential runs.
