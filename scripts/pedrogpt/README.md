# pedrogpt Operations Guide

Runtime operations for the llama-server on pedrogpt (100.121.229.114, RTX 5090 / Blackwell sm_120).

The server runs in **router mode**, serving **two** models. Callers pick one per request via the
`"model"` field in `/v1/chat/completions`:

| API id | Model | MTP | ctx | Resident |
|---|---|---|---|---|
| `qwen3.6-27b-mtp` | Qwen3.6-27B-MTP | yes (~1.4–2.2x, no quality loss) | 216064 | loads on startup |
| `qwen3.8-27b` | Qwen3.8-27B (dense) | no | 262144 | loads on demand |

**Only one is resident at a time.** `qwen3.6-27b-mtp` alone measures 27.9 GB of 32.6 GB VRAM, and two
27B Q4 models are 35.5 GB of weights before any KV cache — they cannot coexist at any context size.
`--models-max 1` makes them swap, which costs ~18 GB of I/O on the first request after a switch but
lets each keep its full context.

MTP requires a single request stream (`--parallel 1`). That is a *per-model* setting and does not
prevent router mode: each model runs as its own child process.

The service is launched by `/opt/llama.cpp/run-server.sh` from `/etc/llama-server.env`, with
per-model tuning in `/etc/llama-server-models.ini` (source: `presets/router.ini`). See
`presets/README.md` for the full flag mapping and `docs/llama-cpp-build.md` for build rationale.

---

## Topology: two servers (chat + embeddings)

MTP and the embeddings endpoint **cannot run in one llama-server process** — the embeddings output
graph crashes the MTP spec-decoding graph on load. So serving is split:

| Server | Where | Model | Purpose |
|--------|-------|-------|---------|
| **chat** | `pedrogpt:8000` (this guide) | `qwen3.6-27b-mtp` (MTP) | chat completions — **no embeddings** |
| **embeddings** | sidecar in the twitch-bot pod, `localhost:8081` | `nomic-embed-text` (768-dim) | `/v1/embeddings` for mem-palace / FAQ |

The embeddings sidecar is a CPU-only llama.cpp build (`--embeddings --pooling mean`); see
`iam_pedro/deployment/embed/` for its Dockerfile. This guide covers the chat server only.

## Endpoints (chat server)

Base URL: `http://100.121.229.114:8000`

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Server health — returns `{"status":"ok"}` when ready |
| `/v1/models` | GET | List the model (`qwen3.6-27b-mtp`) |
| `/v1/chat/completions` | POST | OpenAI-compatible chat completions |
| `/metrics` | GET | Prometheus metrics |

> `/v1/embeddings` is **not** served here — use the embeddings sidecar (`:8081`).

### Check health

```bash
curl http://100.121.229.114:8000/health
```

### List registered models

```bash
curl http://100.121.229.114:8000/v1/models | jq '.data[].id'
```

Expected output (router mode serves both):
```
"qwen3.6-27b-mtp"
"qwen3.8-27b"
```

---

## Calling the model

There is one model id: **`qwen3.6-27b-mtp`**. Pass it in the `"model"` field (OpenAI-compatible).

```bash
# Chat / reasoning / coding — one tuned model for everything
curl http://100.121.229.114:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6-27b-mtp",
    "messages": [{"role": "user", "content": "write a Go HTTP server"}],
    "max_tokens": 500
  }'

# Generate embeddings — NOT on this server. Use the embeddings sidecar (:8081):
#   curl http://localhost:8081/v1/embeddings \
#     -H "Content-Type: application/json" \
#     -d '{"model": "nomic-embed-text", "input": "The quick brown fox"}'
```

### Switching models

Nothing to switch server-side: both models are always registered, and naming one in a request loads
it automatically (evicting the other). Use `switch-model.sh` only to pre-warm before a benchmark or
to free VRAM:

```bash
./switch-model.sh --host pedrogpt list                  # ids + load status
./switch-model.sh --host pedrogpt load   qwen3.8-27b    # pre-warm (~18 GB, evicts the other)
./switch-model.sh --host pedrogpt unload qwen3.8-27b    # free VRAM
```

### Embeddings (separate sidecar)

Embeddings are served by a dedicated CPU llama.cpp sidecar (`nomic-embed-text`, 768-dim,
`--pooling mean`) running on `localhost:8081` in the twitch-bot pod — **not** by this chat server.
See `iam_pedro/deployment/embed/` for the image and `iam_pedro/charts/pedro-bots` for the sidecar
wiring. The split exists because MTP and the embeddings graph can't coexist in one llama-server.

### Streaming Responses

Add `"stream": true` to get token-by-token responses:

```bash
curl http://100.121.229.114:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6-27b-mtp",
    "messages": [{"role": "user", "content": "write a story"}],
    "stream": true
  }'
```

> **Note:** Qwen3.6 has a thinking mode that emits `reasoning_content` before `content`. The server
> launches with `--chat-template-kwargs '{"enable_thinking":false}'` to keep responses direct; pass
> `chat_template_kwargs: {"enable_thinking": true}` per request to re-enable it, and use
> `max_tokens >= 500` so reasoning output isn't truncated.

---

## Debugging

### Check service status

```bash
ssh soypete@100.121.229.114
sudo systemctl status llama-server
```

### Tail live logs

```bash
ssh soypete@100.121.229.114 "sudo journalctl -u llama-server -f"
```

### Common errors

| Error | Cause | Fix |
|-------|-------|-----|
| `activating (auto-restart)` | Service crash loop | Check `journalctl -u llama-server -n 50` |
| `model not found` | Wrong model id in API request | Use `qwen3.6-27b-mtp` (the `--alias`) |
| `unknown argument --spec-type` / `invalid spec-type` | Build predates MTP, or wrong spelling | Rebuild from recent master; `llama-server --help \| grep -i spec` (may be `mtp` vs `draft-mtp`) |
| `--flash-attn: expected value` | Old flag syntax | Use `--flash-attn on` |
| ~11 tok/s, very slow | Mis-built CUDA backend | Rebuild sm_120 + CUDA 12.8 + `FORCE_CUBLAS=OFF`; see `docs/llama-cpp-build.md` |
| Empty `content`, has `reasoning_content` | Thinking mode hit token limit | Increase `max_tokens` or disable thinking |
| CUDA forward compat warning | Non-fatal driver mismatch warning | Ignore — model still loads |

### Inspect the active systemd config

```bash
ssh soypete@100.121.229.114 "systemctl cat llama-server"
```

### Verify the loaded model and MTP

```bash
curl http://100.121.229.114:8000/v1/models | jq '.data[].id'   # -> qwen3.6-27b-mtp
# MTP / spec-decoding shows up in the startup logs:
ssh soypete@100.121.229.114 "sudo journalctl -u llama-server | grep -i 'spec\|draft\|mtp' | tail"
```

---

## Adding or replacing a model

Models are declared in `presets/router.ini` (deployed to `/etc/llama-server-models.ini`), so this is
a config change plus a redeploy — not an env edit:

```bash
# 1. download the GGUF on the box
./switch-model.sh download <org>/<model>-GGUF "*UD-Q4_K_XL*" /opt/models/<model-name>

# 2. add a section to scripts/pedrogpt/presets/router.ini
#      [<api-id>]
#      model = /opt/models/<model-name>/<file>.gguf
#      ctx-size = ...
#    Put MTP flags (spec-type/spec-draft-*) in the section ONLY if that GGUF has a
#    draft head — inheriting them on a non-MTP model crashes it on load.

# 3. redeploy from your workstation
./deploy-presets.sh --env /tmp/llama-server.env

# 4. add a Prometheus job for it (?model=<id>&autoload=false) in
#    llama-cpp-scrapeconfig.yaml and helm/observability/values.yaml
```

VRAM, not config, is the binding constraint: a third 27B-class model still means one resident at a
time and more swap thrash.

When picking a model: check [LiveBench](https://livebench.ai) for scores, find a GGUF on HuggingFace
(prefer `unsloth`/`bartowski`), size it to leave VRAM for the KV cache (dense up to ~30B at Q4 fits
32GB), and prefer a model that ships an MTP head.

---

## Maintenance

### Restart the service

```bash
ssh soypete@100.121.229.114 "sudo systemctl restart llama-server"
```

### View the launch config

```bash
ssh soypete@100.121.229.114 "cat /etc/llama-server.env; cat /opt/llama.cpp/run-server.sh"
```

### Roll back to single-model mode

Router mode is selected purely by the ABSENCE of `-m`, so rollback is a file swap. Snapshot before
deploying, then restore:

```bash
# snapshot BEFORE any deploy
ssh pedrogpt 'sudo cp /etc/systemd/system/llama-server.service /root/llama-server.service.bak \
  && sudo cp /etc/llama-server.env /root/llama-server.env.bak \
  && sudo cp /opt/llama.cpp/run-server.sh /root/run-server.sh.bak'

# roll back
ssh pedrogpt 'sudo cp /root/run-server.sh.bak /opt/llama.cpp/run-server.sh \
  && sudo cp /root/llama-server.env.bak /etc/llama-server.env \
  && sudo cp /root/llama-server.service.bak /etc/systemd/system/llama-server.service \
  && sudo rm -f /etc/llama-server-models.ini \
  && sudo systemctl daemon-reload && sudo systemctl restart llama-server'
```

Then revert both ScrapeConfigs (drop the `params:` blocks and the second job). The Qwen3.8 GGUF can
stay on disk — it costs disk, not VRAM.

### Check Prometheus metrics

In router mode `/metrics` is proxied to the child and **requires** `?model=`; plain `/metrics`
returns HTTP 400. `/health` is unaffected.

```bash
curl 'http://100.121.229.114:8000/metrics?model=qwen3.6-27b-mtp&autoload=false' | grep -E 'llamacpp:'
curl http://100.121.229.114:8000/health
```

### GPU memory usage

```bash
ssh soypete@100.121.229.114 "nvidia-smi --query-gpu=memory.used,memory.free,memory.total --format=csv"
```

---

## Files

| Path | Description |
|------|-------------|
| `/opt/llama.cpp/` | llama.cpp build (CUDA 12.8, sm_120) |
| `/opt/llama.cpp/build/bin/llama-server` | server binary |
| `/opt/llama.cpp/run-server.sh` | launcher wrapper (starts the router; no `-m`) |
| `/opt/models/qwen3.6-27b-mtp/` | Qwen3.6-27B MTP GGUF |
| `/opt/models/qwen3.8-27b/` | Qwen3.8-27B GGUF |
| `/etc/systemd/system/llama-server.service` | systemd unit (runs `run-server.sh`) |
| `/etc/llama-server.env` | router config: `MODELS_PRESET`, `MODELS_MAX`, `PORT`, `HF_TOKEN` |
| `/etc/llama-server-models.ini` | **per-model tuning** (from `presets/router.ini`) |
| `scripts/pedrogpt/presets/router.ini` | source of truth for the models served |
| `scripts/pedrogpt/presets/*.ini` (others) | DEPRECATED, retired models, not deployed |
