# llama.cpp Model Presets

pedrogpt (RTX 5090, sm_120, 32GB VRAM, 64GB RAM) runs `llama-server` in **router mode**, serving
**two** models that **swap in and out of VRAM on demand**.

The live config is **`router.ini`** in this directory, deployed to `/etc/llama-server-models.ini` by
`deploy-presets.sh`. Every other `.ini` here is marked `DEPRECATED` and is not read by anything.

| Section / API id | Model | Quant | MTP | ctx | Loads on startup |
|---|---|---|---|---|---|
| `qwen3.6-27b-mtp` | Qwen3.6-27B-MTP | UD-Q4_K_XL (~17.9 GB) | yes (baked-in head) | 216064 | yes |
| `qwen3.8-27b` | Qwen3.8-27B | UD-Q4_K_XL (17.56 GB) | no | 262144 (full native) | no |

Callers pass the id in the `"model"` field of `/v1/chat/completions`. `qwen3.6-27b-mtp` is unchanged
from single-model mode, so existing callers (OpenWebUI, `benchmark/`, SuperAgentPedro, iam_pedro,
pedro-bots) need no changes.

## How router mode works

`llama-server` is started **without `-m`/`--model`** — that absence is what selects router mode. The
router process serves no model itself and never touches the GPU; it spawns **one child process per
model** on demand, and each child inherits the router's environment plus its own preset section.

Because children are separate processes, per-model settings genuinely stay per-model. That is why
`parallel = 1` (required by MTP) on one model does not constrain the other.

## Where each flag lives

Single-model mode passed every flag on one command line. Router mode splits them three ways. This
table maps the old `run-server.sh` invocation onto the new layout — use it when something seems
"missing":

| Flag | Now lives in | Applies to |
|---|---|---|
| `--jinja` | `[*]` in `router.ini` | **both models** — needed for tool calls |
| `--no-webui` | `[*]` | both |
| `--metrics` | `[*]` | both (router proxies `/metrics` to the child) |
| `--flash-attn on` | `[*]` | both (also a prerequisite for q8_0 KV cache) |
| `--host`, `--port` | `run-server.sh` | router process |
| `--models-preset`, `--models-max`, `--models-autoload` | `run-server.sh` / env file | router process |
| `-m` / `--model` | section `model =` key | per model |
| `--alias` | the **section name** is the API id | per model |
| `--ctx-size` | section | per model |
| `--n-gpu-layers`, `--parallel` | section | per model |
| `--batch-size`, `--ubatch-size` | section | per model |
| `--mlock` | section | **model 1 only** (see below) |
| `--cache-type-k` / `-v` | section | per model |
| `--spec-type`, `--spec-draft-n-max` | section | **model 1 only** |
| `--cache-type-k-draft` / `-v-draft` | section | model 1 only |
| `--temp`, `--top-k`, `--top-p`, `--presence-penalty`, `--min-p` | section | per model |
| `--chat-template-kwargs` | section | model 1 |

Preset-only keys (not command-line flags): `load-on-startup`, `stop-timeout`.

Precedence, highest first: **CLI args** → **model section** → **`[*]`**.

> **Do not add per-model tuning flags to `run-server.sh`.** CLI args outrank preset sections and hit
> *every* model. `--spec-type` there would crash the non-MTP model on load.

### Why `spec-type` and `mlock` are not in `[*]`

- **`spec-type = draft-mtp`** — Qwen3.8-27B has no draft head. Inheriting this flag makes that child
  fail on load. MTP flags belong only to `qwen3.6-27b-mtp`.
- **`mlock`** — locking 17.5 GB of a model that is designed to be evicted fights the swap. Only the
  startup model locks its weights.

## VRAM: why the models swap instead of coexisting

Measured on the box, single model loaded:

```
$ nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
1737, /opt/llama.cpp/build/bin/llama-server, 27952 MiB
$ nvidia-smi --query-gpu=memory.total,memory.free --format=csv
32607 MiB, 4104 MiB
```

`qwen3.6-27b-mtp` at ctx 216064 uses **27.9 GB of 32.6 GB**, leaving 4.1 GB. Model 2's weights alone
are 17.56 GB.

Reducing context does not rescue it: **17.9 + 17.56 = 35.5 GB of weights exceeds the 32.6 GB card
before a single KV byte**. Two 27B Q4 models cannot be co-resident on this GPU at any context size.

Hence `--models-max 1`. The upside: since only one model is ever resident, **each keeps its full
context** — there was no need to shrink the 216k window.

**The tradeoff is swap latency.** Each switch unloads ~18 GB and reads ~18 GB from disk, so the first
request after switching models stalls noticeably (tens of seconds cold). Steady-state throughput on
either model is unaffected. `load-on-startup = true` on the MTP model means the default model is hot
after a restart and only the secondary pays a cold start.

## Context sizing

Both models are trained to **262144** tokens (`n_ctx_train`).

`qwen3.8-27b` runs at the **full 262144**. That is affordable because only **16 of its 64 layers use
full attention** (`full_attention_interval = 4`; the other 48 are `linear_attention` and carry no
growing KV cache). With 4 KV heads x 256 head_dim and `q8_0` K/V, KV at 262144 is **~8.6 GB**, against
a ~15 GB budget (32.6 GB card - 17.56 GB weights).

`qwen3.6-27b-mtp` runs at **216064**, below its 262144 training window — this is why the log shows
`n_ctx_seq (216064) < n_ctx_train (262144) -- the full capacity of the model will not be utilized`.
Raising it is **unverified**: measured usage is 27.95 GB at 216064, so extrapolating the non-weight
cost (~46.5 MB per 1k tokens) puts 262144 at **~30.1 GB of 32.6 GB — only ~2.5 GB headroom**.

To test it, change `ctx-size` in that section, redeploy, and watch the load:

```bash
ssh pedrogpt 'nvidia-smi --query-gpu=memory.used,memory.free --format=csv'
ssh pedrogpt 'journalctl -u llama-server -n 50 --no-pager | grep -i "cuda\|buffer\|error"'
```

Roll back the `ctx-size` if it OOMs or if free VRAM drops below ~1 GB.

> Because `--models-max 1` means each model has the whole card to itself, context is bounded by the
> single largest model, not by the sum. Adding a third model does not shrink anyone's context.

## Reasoning / thinking control

Two **different** mechanisms are easy to confuse:

| | `--reasoning-budget N` | `reasoning_effort` |
|---|---|---|
| Kind | llama.cpp CLI flag / preset key | key inside `chat-template-kwargs` |
| Type | **integer only** — `-1`, `0`, or `N>0` | **keyword** — model-defined |
| Values | `-1` unrestricted (default), `0` end immediately, `N` cap at N tokens | see below |
| Enforced by | llama.cpp's sampler — a hard stop | the model's Jinja template |

`--reasoning-budget` rejects anything below `-1` (`common/arg.cpp`) and does **not** accept
`low`/`medium`/`high`. Passing a keyword there fails to parse. Related flags: `-rea, --reasoning
on|off|auto` (a plain switch) and `--reasoning-format` (where thoughts are returned, not whether
they happen).

`reasoning_effort` is passed straight through to the model — llama.cpp neither validates nor
interprets it — so **the valid values are defined by the model's chat template**, which is why no
list appears in llama.cpp's docs.

### Values this box's models accept

**`qwen3.8-27b`** — its embedded template accepts exactly three, and raises
`Unexpected reasoning effort ... Supported types are xhigh (default), medium, and low.` on anything
else:

| Value | Notes |
|---|---|
| `xhigh` | **the template's default** — maximum effort |
| `medium` | **what we set** — good latency/quality trade |
| `low` | brief, focused thinking |

`high` is accepted but **silently remapped onto `xhigh`**, so it is not a distinct tier — which is
why advice to prefer "medium or max" over "high/xhigh" holds here: there is no separate `high` to gain from.

Left unset, this model reasons at `xhigh` on **every** request. That is worth knowing because it
makes short-`max_tokens` calls appear to return an empty reply: the whole budget is consumed by
thinking, and the content field comes back empty while `reasoning_content` is populated. We set
`medium` explicitly in `router.ini`.

**`qwen3.6-27b-mtp`** disables thinking outright with `chat-template-kwargs =
{"enable_thinking":false}` — a Qwen-template-specific key that predates `reasoning_effort`.

To inspect what any GGUF supports, read its embedded template:

```bash
# dump tokenizer.chat_template from the GGUF and grep for the key
llama-gguf /opt/models/<model>/<file>.gguf r n | grep -i chat_template
```

Reference: `tools/server/README.md` (the `--chat-template-kwargs` flag, and the per-request
`chat_template_kwargs` body field) and `docs/preset.md` for the INI form.

## Metrics changed under router mode

`/metrics` is proxied to the child and **requires** `?model=<id>`, else HTTP 400
(`model name is missing from the request`):

```bash
curl 'http://pedrogpt:8000/metrics?model=qwen3.6-27b-mtp&autoload=false'
```

`autoload=false` matters: without it, a 15s Prometheus scrape of the *idle* model would force-load
18 GB and thrash the GPU permanently. The idle model's scrape failing is correct behaviour, not an
outage. Both ScrapeConfigs (`../llama-cpp-scrapeconfig.yaml` and
`helm/observability/templates/external-scrapes.yaml`) set these params.

**`/health` is unaffected** and needs no `?model=` — it stays a plain router-level check.

## Managing models at runtime

```bash
curl -s http://pedrogpt:8000/v1/models | jq '.data[].id'     # list + load status
../switch-model.sh load   qwen3.8-27b                        # POST /models/load
../switch-model.sh unload qwen3.6-27b-mtp                    # POST /models/unload
```

## Downloading the models

```bash
hf download unsloth/Qwen3.6-27B-MTP-GGUF --include "*UD-Q4_K_XL*" \
  --local-dir /opt/models/qwen3.6-27b-mtp
hf download unsloth/Qwen3.8-27B-GGUF --include "Qwen3.8-27B-UD-Q4_K_XL.gguf" \
  --local-dir /opt/models/qwen3.8-27b
```

Models are pre-downloaded to local paths rather than resolved via `-hf` at boot: with
`Restart=on-failure`, a start that blocks on a 17.5 GB fetch turns a network blip into a retry loop.

> Qwen3.8-27B has an MTP draft head available *separately* as `MTP/mtp-Qwen3.8-27B-Q4_0.gguf`
> (1.37 GB). It is **not** baked into the Q4_K_XL file. Wiring it up would need `spec-type` plus
> `spec-draft-model` in that section — deliberately not done.

## Adding a third model

VRAM is the binding constraint, not config: a third 27B-class model still means one resident at a
time and more swap thrash. If it is small (≤10 GB) consider a second `llama-server` on port 8001
instead, so both stay hot.

Otherwise: add a section to `router.ini`, download the GGUF, add a ScrapeConfig job with
`?model=<id>&autoload=false`, and redeploy.

## Historical note

This box previously ran a 5-model router (GLM-4.7-Flash, Nemotron-3-Super-120B, Qwen3-Next-80B,
Qwen2.5-VL-32B, plain Qwen3.6-27B), then a single-model MTP server. The deprecated `.ini` files here
describe those retired models.

Earlier revisions of this README stated that MTP "cannot run in router mode." **That was wrong** —
it conflated `parallel > 1` (which MTP does preclude) with router mode itself. Router children are
separate processes, so `parallel = 1` is preserved per-model.
