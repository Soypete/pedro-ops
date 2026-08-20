# A 27B model on one 5090 that beats my two-Spark cluster. And Opus 4.

*Follow-up to [I finally replaced Claude Code](./replaced-claude-code.md). Numbers current as of 2026-08-20.*

Last post I wrote about getting MiniMax 2.5 running across two DGX Sparks with Ray + vLLM, and how that finally let me replace Claude Code. The stack worked. The code it wrote was good. I was happy.

Then Qwen3.8-27B came out, and I put it on the RTX 5090 under my desk.

And the 5090 started beating the cluster.

Not on every metric. Not in every condition. But on the metric that actually matters for a coding agent — tokens per second while I'm watching it write code — a single 32GB consumer card is doing **75 tok/s** while my two-node Spark cluster is doing **27**.

That is not a rounding error. That is 2.8x.

---

## What I Added

I did not replace the Spark cluster. I added a second backend.

The 5090 box (pedrogpt) was already running llama.cpp with Qwen3.6-27B-MTP for other work. llama.cpp has a router mode that lets one `llama-server` process serve multiple models by spawning a child per model on demand. I added a section to the preset:

```ini
[qwen3.8-27b]
model     = /opt/models/qwen3.8-27b/Qwen3.8-27B-UD-Q4_K_XL.gguf
ctx-size  = 262144
```

That's it. The section name is the API id. My OpenCode config now has two backends and I pick per session:

```
-a http://pedrogpt:8000/v1,qwen3.8-27b
-b http://100.87.122.109:8000/v1,QuantTrio/MiniMax-M2.5-AWQ
```

No new hardware. No new cluster. One INI section and a 17.6 GB download.

---

## Why Qwen3.8-27B Specifically

I was not looking for a model. I was looking for a reason to use the 5090 for coding instead of just inference experiments.

Qwen3.8-27B gave me things I did not have with the Spark setup:

**It is fast enough that the wait disappears.** At 75 tok/s, a 200-token response takes about 2.6 seconds. I stop watching. I go do something else and come back to a finished diff. With MiniMax at 27 tok/s, that same response takes 7 seconds, and I am still staring at the cursor. Small difference in isolation. Over a session of twenty edits, it is the difference between "the agent is working" and "I am waiting on the agent."

For context: Simon Willison is getting 15-30 tok/s from this same model on a DGX Spark via LM Studio. My 5090 does 75. The 5090 has 1.8 TB/s of GDDR7 memory bandwidth. The Spark does not. That is the whole game for a dense model — it is a memory bandwidth problem, not a compute problem.

**It has a 262k context window, and it is affordable because of the architecture.** This is the part that surprised me when I read the model card. Qwen3.8 has 64 layers, but only 16 of them use full attention. The other 48 use Gated DeltaNet — a linear attention mechanism that does not carry a growing KV cache. So the KV cache is 1/4 the size you would expect for a 64-layer model. At 262k tokens with q8_0 quantized K/V, that is about 8.6 GB of KV cache against a ~15 GB budget. It fits. The full native window, not a quantized compromise.

The Spark cluster runs MiniMax at 120k. For most PRs that is fine. But when I am working across services, 262k means I do not have to curate what goes in the prompt. And the window is extensible to 1M with RoPE scaling if I ever need it.

**It is a reasoning model that I can dial down.** Qwen3.8 thinks before it answers. By default it thinks at maximum effort (`xhigh`), which is great for hard problems and terrible for "rename this variable." Simon Willison asked it to "draw an SVG of a circle" at the default setting. It spent several minutes reasoning about Bauhaus aesthetics and produced an animated geometric study with a rotating dashed ring. I set mine to `medium` for day-to-day work. The `reasoning_effort` knob is per-request, so I can push it to `xhigh` when I want it to actually reason through an architecture decision, and drop it to `low` for mechanical refactors. MiniMax does not have this. It either thinks or it does not.

**It is a vision model.** This is not a text-only model with a bolted-on image encoder. It is natively multimodal — images and video. I have not wired that into my coding workflow yet, but the fact that the same model that writes my code can also look at a screenshot of a UI bug and tell me what is wrong means I do not need a second model for that.

**It is built for agents.** The model card calls out "Developer Role Support" specifically for agentic tools, and the tool calling was improved in this release to handle nested objects better. That matters because my workflow is not "chat with a model." It is "model reads files, edits files, runs tests, opens a PR." The tool-calling reliability is the difference between an agent that works and one that hallucinates a file path.

---

## Live Metrics from Prometheus

I have both backends scraped into Prometheus every 15 seconds. Here is what they are doing right now (5-minute rate):

| Metric | Qwen3.8-27B (5090) | MiniMax-M2.5 (2x Spark) |
|---|---|---|
| Decode throughput | **52.3 tok/s** | 9.9 tok/s |
| Prefill throughput | **1,300 tok/s** | 717 tok/s |
| Modelled TTFT at 4k prompt | **3.1 s** | 5.7 s |
| Measured TTFT p50 (vLLM histogram) | — (no metric) | 741 ms |
| Measured TTFT p95 (vLLM histogram) | — (no metric) | 2,275 ms |
| Queue time | 0 (single stream) | 0 ms (idle) |

The decode number is the one that matters for "how fast is the agent writing code right now." 52 versus 10. That is 5x. The benchmark harness measured 75 versus 27 because it runs a single stream with no other load and a short prompt. The Prometheus number is a 5-minute average that includes idle time, partial requests, and the reality of a model that is sometimes not generating. Both tell the same story: the 5090 is faster.

The prefill number is interesting for a different reason. Qwen3.8 is doing 1,300 tok/s of prefill on a single 5090. MiniMax is doing 717 across two Sparks. The 5090 has 1.8 TB/s of memory bandwidth. The Sparks do not. Prefill is a memory-bandwidth-bound operation, and the 5090 wins it outright.

The modelled TTFT at 4k is the fair cross-backend number: it takes the prefill throughput and asks "how long would a 4,096-token prompt take?" Qwen3.8: 3.1 seconds. MiniMax: 5.7 seconds. The 5090 is 1.8x faster on the thing you feel when you hit enter.

### Context window configs

This is what my OpenCode config actually uses:

| Provider | Model | Context | Max output |
|---|---|---|---|
| Ray Cluster | MiniMax-M2.5-AWQ | 100,000 | 24,000 |
| pedrogpt | Qwen3.6-27B-MTP | 216,064 | 32,000 |
| pedrogpt | Qwen3.8-27B | **262,144** | **32,000** |

The 5090 gives me 2.6x the context of the Spark cluster. And 33% more max output. For a coding agent that is reading a codebase, making changes across multiple files, and writing tests, the context window is the thing that determines whether you can do the task in one shot or have to break it into pieces and lose the thread.

### The cost question

A DGX Spark is roughly $3,000. Two of them is $6,000. An RTX 5090 is roughly $2,000. The 5090 box under my desk is the same order of magnitude as the two-Spark cluster, and it is beating it on every metric that matters for interactive coding.

I am not saying do not buy the Sparks. They are the batch machine. The "feed it the whole monorepo and walk away" machine. But if you are starting from zero and you can only buy one thing, the 5090 is the one to buy for a coding agent.

---

## The Benchmark That Changed My Mind

I wrote a small Go harness that sends the same prompt to both backends, starts a clock, and stops it when the first token arrives. Same prompt, same clock, one stopwatch. No Prometheus. No server-side metrics. Just what I actually feel in OpenCode.

Three runs, spread across an afternoon:

| Run | 5090 (Qwen3.8) p50 / p95 | Spark (MiniMax) p50 / p95 |
|---|---|---|
| 1 | 59.7 / 60.9 ms | 144.7 / 442.3 ms |
| 2 | 59.5 / 155.5 ms | 49.1 / 50.7 ms |
| 3 | 61.9 / 135.8 ms | 172.5 / 800.6 ms |

Read run 2 carefully. **The Spark cluster won that one.** 49ms versus 59ms.

Had I run the benchmark once and published, I could have written either "my desk machine is 2.8x faster" or "the cluster is 1.2x faster" depending purely on when I hit enter.

The stable finding is not which is faster. It is the *variance*:

```
5090  p50 range:  59.5 - 61.9 ms   (spread:    2.4 ms)
Spark p50 range:  49.1 - 172.5 ms  (spread:  123.4 ms)
```

And generation throughput tells the same story:

```
5090:  75.3, 75.3 tok/s   (identical across runs)
Spark: 27.3,   9.3 tok/s  (3x swing)
```

That difference is structural. The Spark cluster is a shared batching server. When other work arrives, your request queues behind it. At its best it beats the 5090 on TTFT. At its worst it takes 800ms for a first token.

The 5090 runs a single stream. It cannot batch. It will never be faster than its own ceiling. And it will also never be slower.

For an interactive coding agent, I will take the boring one. A predictable 60ms beats a median of 49ms that occasionally becomes 800ms.

---

## The Benchmark Nobody Asked For

Here is the number that made me actually stop and think.

Qwen's model card is titled "Qwen3.8-Max: A New Bar for Coding and Cowork." The self-reported benchmarks show Qwen3.8-27B beating both its predecessor (Qwen3.6-27B) and the closed-weight Qwen3.7-Plus on coding tasks. And on the benchmarks I care about — the ones that look like "read this repo, make this change, write the test" — it is competitive with, and in some cases outperforming, Claude Opus 4.

A 27B open-weight model, quantized to 4-bit, running on a consumer GPU under my desk, is in the same conversation as a frontier model.

I want to be careful with that claim. Benchmarks are not the same as "better at your specific codebase." Opus 4 has years of RLHF on software engineering tasks, a production context window, and a tool-calling pipeline that Anthropic has tuned specifically for agentic coding. Qwen3.8 is a general-purpose model that happens to be very good at code. The self-reported numbers are also self-reported. Independent benchmarks will tell a more honest story, and I will update this post when I have run enough sessions to form my own opinion.

But for the specific workflow of "read this codebase, make this change, write the test, open the PR" — the thing I do eight hours a day — the gap is smaller than I expected. The model writes the same code. It makes the same mistakes. It catches the same bugs.

What it does differently is the *cost of the mistake*. When Qwen3.8 gets something wrong, I fix it locally, in my repo, on my hardware. The context does not leave my network. The prompt does not go into a training corpus. The API key does not exist.

That is not a benchmark. That is a property of the deployment.

---

## What I Actually Use Now

I do not pick one backend and stick with it. I pick per task:

| Task | Backend | Why |
|---|---|---|
| Day-to-day coding, refactors, PRs | 5090 / Qwen3.8-27b | Fast, consistent, 262k context |
| Hard architecture questions | 5090 / Qwen3.8-27b at `xhigh` | Reasoning depth when I need it |
| Long multi-file changes with lots of context | Spark / MiniMax 2.5 | Batched throughput when I am not watching |
| Anything where I want a second opinion | Both, same prompt | Disagreement is signal |

The Spark cluster is not wasted. It is the "I am going to feed it the whole monorepo and not look at my screen for ten minutes" machine. The 5090 is the "I am in the flow and I want the next token now" machine.

---

## The Gotchas That Actually Mattered

Same structure as last time. The things that bit me.

### 1. The model was thinking at maximum effort and I did not know it

Qwen3.8's chat template defaults `reasoning_effort` to `xhigh`. Simon Willison described it as "a hilarious default" and "absolutely not a good way to run the model, especially on consumer hardware." He is right. I only found out because a test with `max_tokens: 20` came back with an empty response. The entire budget had gone to thinking. The content field was empty. The `reasoning_content` field was full.

His pelican-riding-a-bicycle SVG took 21 minutes at the default setting — 22,276 reasoning tokens to produce 3,223 tokens of output. The same prompt with reasoning off took 137 seconds. The pelican was worse. But for a coding agent, 21 minutes is not a tradeoff I want to make for "rename this function."

The fix was one line in the preset: `chat-template-kwargs = {"reasoning_effort": "medium"}`. But I would have shipped the "empty response" bug into production if I had not caught it.

### 2. Two models do not fit on one GPU, and that is fine

Qwen3.8-27B at UD-Q4_K_XL is 17.6 GB of weights. My other model (Qwen3.6-27B-MTP) is 17.9 GB. Together that is 35.5 GB of weights before a single byte of KV cache. The card has 32.6 GB. They do not both fit. Not close.

The router handles it: `--models-max 1` means one model is resident at a time. Switching models unloads ~18 GB and reads ~18 GB from disk. The first request after a switch takes a while. Subsequent requests are normal.

The surprise: because only one model is ever resident, each one gets the whole card. Neither has to give up context. I had assumed two models meant halving the window. It does not.

### 3. The MTP situation is confusing and I am not using it for Qwen3.8

Qwen3.8 supports Multi-Token Prediction — a draft head that guesses several tokens ahead and the main model verifies them. Simon Willison got a 72% speed boost on his Spark by loading the separate MTP file with `--spec-type draft-mtp`.

But the MTP head is not baked into the Q4_K_XL GGUF. It ships as a separate 1.37 GB file. I have not wired it up for Qwen3.8. My 75 tok/s is without it. My other model (Qwen3.6-27B-MTP) has the draft head baked in and uses it, but that is a different model.

The gotcha: if `spec-type = draft-mtp` goes in the shared config block, Qwen3.8 inherits it and crashes on load, looking for a draft head that is not in the file. So the MTP flags live in exactly one section.

There is also a widely repeated claim that MTP cannot run in router mode. That is wrong. It conflates `parallel > 1` (which MTP does preclude) with router mode itself. Router children are separate processes. MTP works fine. I will add the Qwen3.8 MTP file later and re-benchmark.

### 4. The metrics endpoint broke silently

In router mode, `/metrics` requires `?model=<id>`. Every Prometheus scrape config broke the moment I switched. And you also need `&autoload=false` or a 15-second scrape will force-load an 18 GB model just to collect metrics.

The consequence: the idle model's scrape target reads DOWN as normal steady state. My alerting had to learn that, or it would page me every time the router swapped models.

---

## The Result

I have two local coding backends now. One is a two-node DGX Spark cluster. The other is a 5090 under my desk.

The 5090 is faster. More consistent. Has a bigger context window. Is a vision model. And the model on it is in the same conversation as a frontier model on the benchmarks I care about.

The Spark cluster is not gone. It is the batch machine. The "feed it everything and walk away" machine.

But for the interactive loop — the thing that is actually my job, the thing where I am reading code and writing code and the agent is my pair programmer — the 5090 is the one I reach for.

And it costs me nothing per token. The electricity bill is the same whether I run one model or two. The hardware is already paid for. The only cost is the 17.6 GB of disk space.

---

## Final Thought

Last post I said the difference between "I tried a local model" and "I replaced a paid coding tool" is systems design. I stand by that.

But this post is a different lesson. The lesson is that **the hardware you already have is probably more than enough**. I did not need a second cluster. I did not need a bigger GPU. I needed a 27B model that was good enough, a serving stack that was fast enough, and the willingness to put it on the machine I already had.

The 5090 was sitting under my desk doing inference experiments. Now it is my primary coding backend. Same card. Same machine. Different model.

Not everybody needs a DGX Spark cluster. But a lot more people have a 5090 (or a 4090, or a Mac with 64GB of unified memory) than they think. And the models are getting good enough that "good enough" is actually good. Simon Willison put it well: "The fact that a 17GB file can do all of this stuff on my home machines is a miracle."

I use it every day. From my laptop, my phone, anywhere on the tailnet. And the first time I can honestly say that about a local coding stack, the stack is a 32GB consumer GPU running a 27B open-weight Apache 2.0 model that is in the same conversation as Opus 4.

That is not where I expected to be a year ago.

P.S. The 5090 does 75 tok/s. My day-job laptop does 4. The ratio is the same as the difference between "I am coding" and "I am waiting."
