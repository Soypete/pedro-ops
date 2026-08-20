# Two models, one GPU: llama.cpp router mode and what it cost me

*Draft — numbers current as of 2026-08-20.*

I run a coding agent against two very different inference backends. One is a Ray cluster
running vLLM with MiniMax-M2.5-AWQ. The other is a single machine under my desk with an
RTX 5090 in it, running llama.cpp. I wanted a second model on the 5090 box, and I wanted
to know which backend was actually faster.

Both turned out to be more interesting than I expected.

## Part 1: two models on a 32GB card

llama.cpp has a **router mode** that most people seem not to know about. You start
`llama-server` with *no* `-m` flag:

```bash
llama-server --models-preset /etc/llama-server-models.ini --models-max 1
```

The absence of `-m` is what selects it. The router process loads no model and never
touches the GPU. Instead it spawns **one child process per model**, on demand, and routes
requests by the `model` field in `/v1/chat/completions`.

Models are declared in an INI file:

```ini
[qwen3.6-27b-mtp]
model            = /opt/models/qwen3.6-27b-mtp/Qwen3.6-27B-UD-Q4_K_XL.gguf
ctx-size         = 216064
spec-type        = draft-mtp
spec-draft-n-max = 2
mlock            = true
load-on-startup  = true

[qwen3.8-27b]
model     = /opt/models/qwen3.8-27b/Qwen3.8-27B-UD-Q4_K_XL.gguf
ctx-size  = 262144
```

The section name becomes the API model id, which meant I could keep `qwen3.6-27b-mtp`
exactly as it was and not touch a single downstream caller.

### They do not both fit, and no amount of tuning fixes that

The first thing I checked was whether both could be resident at once. They cannot, and
it is not close:

```
$ nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
1737, /opt/llama.cpp/build/bin/llama-server, 27952 MiB
```

One 27B model at Q4 with a 216k context is using **27.9 GB of 32.6 GB**. The second
model's *weights alone* are 17.56 GB. Even at a trivial context, 17.9 + 17.56 = **35.5 GB
of weights before a single byte of KV cache** — over a 32.6 GB card.

So `--models-max 1`, and the router evicts one model to load the other.

The surprise was that this is *better* than it sounds. Because only one model is ever
resident, each one gets the whole card, and **neither has to give up context**. I had
assumed two models meant halving the context window. It doesn't.

### Where per-model flags live matters enormously

Router mode splits configuration three ways: router-level CLI flags, a shared `[*]`
block, and per-model sections. Getting this wrong breaks things in a way that is
non-obvious.

My first model uses **MTP** (multi-token prediction — a draft head baked into the GGUF
that gives self-speculative decoding, roughly 1.4–2.2x, no quality loss). My second model
has no draft head. If `spec-type = draft-mtp` goes in the shared `[*]` block, the second
model inherits it and **crashes on load**, looking for a draft head that isn't there.

Same for `mlock`: locking 17.5 GB of a model that is designed to be evicted fights the
swap you just configured.

So: `spec-type`, `spec-draft-*` and `mlock` live in exactly one section. `--jinja`,
`--metrics`, `--no-webui` and `--flash-attn` go in `[*]` because both models want them.

There is a widely repeated claim — which was in my own repo's docs, written by me — that
**MTP cannot run in router mode** because MTP requires `--parallel 1`. That is wrong. It
conflates `parallel > 1` (which MTP genuinely does preclude) with router mode itself.
Router children are *separate processes*, so `parallel = 1` on one model does not
constrain the other at all. MTP works fine.

### Three things that bit me

**A phantom model called `default`.** Every llama.cpp preset example starts with
`version = 1`. Include that line and you get a third, non-existent model in `/v1/models`
that shows up in your model picker and fails when selected. Any key above the first
section header is parsed into an implicit section. Upstream's own `docs/preset.md` omits
the line; the server README includes it. Drop it.

**`/metrics` starts returning HTTP 400.** In router mode the metrics endpoint is proxied
to the child process and *requires* `?model=<id>`. Every Prometheus scrape config breaks
silently the moment you switch. Worse, you also want `&autoload=false` — otherwise a
15-second scrape interval will force-load an 18 GB model just to collect metrics, and
your GPU will thrash forever. The consequence is that **the idle model's scrape target
reads DOWN as normal steady state**, which means your alerting needs to know that:

```
PedroTargetDown    up{job=~"..."} == 0          # llama-cpp deliberately excluded
PedroLlamaCppDown  sum by (instance) (up{job="llama-cpp"}) == 0
```

Without that split, every model switch pages you at 3am. (`/health` is unaffected and
still works without a param.)

**The model was reasoning at maximum effort by default.** Qwen3.8's chat template
defaults `reasoning_effort` to `xhigh`. I only noticed because a test with
`max_tokens: 20` came back with an empty response — the entire budget had gone to
thinking, and the content field was empty while `reasoning_content` was full.

This is worth separating clearly, because two knobs get confused:

| | `--reasoning-budget N` | `reasoning_effort` |
|---|---|---|
| Type | **integer only** (`-1`, `0`, `N>0`) | **keyword** |
| Enforced by | llama.cpp's sampler, a hard stop | the model's Jinja template |
| Values | unrestricted / immediate / N tokens | model-defined |

`--reasoning-budget` will not accept `medium`. And the valid keywords are defined by the
model, not by llama.cpp — which is why no list appears in llama.cpp's docs. For Qwen3.8,
reading the template embedded in the GGUF gives exactly three: **`xhigh` (default),
`medium`, `low`**. `high` is accepted but silently remapped onto `xhigh`, so it is not a
distinct tier — which explains advice I'd been given that "high and xhigh show
non-impactful gains."

## Part 2: measuring it, and why the obvious approach fails

With two backends in play I wanted a straight answer on time-to-first-token. The obvious
move is to scrape both servers' Prometheus endpoints. That does not work, for two
separate reasons:

**vLLM's prefill throughput is inflated.** It exposes `request_prefill_time_seconds`,
which sounds perfect, but that is *wall-clock per request* while vLLM prefills many
requests concurrently in a batch. Summing it undercounts real compute time. My first
derived number was 214,000 tokens/sec, which is obvious nonsense. Filtering to
`prompt_tokens_by_source{source="local_compute"}` — because ~92% of prompt tokens on that
cluster are prefix-cache hits that are never prefilled at all — brought it to 70,000,
still too high to publish.

**llama.cpp has no TTFT metric at all.** Only cumulative counters. Any TTFT figure for it
has to be modelled from prefill throughput, which is a model, not a measurement.

So I wrote a small harness that does the honest thing: send the same prompt to both
backends, start a clock, stop it when the first SSE chunk arrives.

Two bugs surfaced immediately, both of which would have produced a confidently wrong
published number:

1. **vLLM streams reasoning as `reasoning`; llama.cpp uses `reasoning_content`.** I
   decoded only the latter, so every vLLM chunk looked empty and the backend appeared to
   return nothing at all. If you build one of these, handle both field names.
2. Neither server includes a `usage` block in a stream unless you set
   `stream_options.include_usage`, so token counts and tok/s silently read zero.

## Part 3: the results, and the thing I didn't expect

Three runs, spread across an afternoon, same prompt, same harness:

| Run | pedrogpt p50 / p95 | Spark p50 / p95 |
|---|---|---|
| 1 | 59.7 / 60.9 ms | 144.7 / 442.3 ms |
| 2 | 59.5 / 155.5 ms | **49.1 / 50.7 ms** |
| 3 | 61.9 / 135.8 ms | 172.5 / 800.6 ms |

Read run 2 carefully: **Spark won that one.** Had I run the benchmark once and published,
I could have written either "my desk machine is 2.8x faster" or "the cluster is 1.2x
faster" depending purely on when I hit enter. That is the single most important thing I
learned here.

The stable finding isn't which is faster. It's the *variance*:

```
pedrogpt p50 range:  59.5 - 61.9 ms   (spread:   2.4 ms)
spark    p50 range:  49.1 - 172.5 ms  (spread: 123.4 ms)
```

And generation throughput tells the same story:

```
pedrogpt:  75.3, 75.3 tok/s   (identical across runs)
spark:     27.3,  9.3 tok/s   (3x swing)
```

That difference is structural, not noise. Spark is a shared batching server: when other
work arrives, your request queues behind it, and at its best it beats the 5090 outright.
pedrogpt runs a single stream with `parallel = 1` — it cannot batch, it will never be
faster than its own ceiling, and it will also never be slower.

For an interactive coding agent, I'll take the boring one. A predictable 60ms beats a
median of 49ms that occasionally becomes 800ms.

The throughput number is the one I'd actually defend, because two independent methods
agree on it: the client harness measured ~75 tok/s for pedrogpt, and Prometheus scraping
llama.cpp's own counters independently reported 75.8.

## What I'd tell someone starting this

- Router mode is real and works, and MTP works inside it. Ignore the claim that it doesn't.
- Drop the `version = 1` line from your preset.
- Fix your Prometheus scrapes *before* you switch, not after, and use `autoload=false`.
- Teach your alerting that an idle model reading DOWN is normal.
- Check what your model's template defaults `reasoning_effort` to. Mine was at maximum
  and I hadn't noticed.
- Measure TTFT client-side, from real requests. Run it more than once, at different times
  of day, and publish the spread rather than the median.

---

*Config and the benchmark harness are in [pedro-ops](https://github.com/Soypete/pedro-ops)
under `scripts/pedrogpt/`.*
