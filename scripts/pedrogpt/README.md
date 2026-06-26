# pedrogpt Operations Guide

Runtime operations for the llama-server on pedrogpt (100.121.229.114, RTX 5090 / Blackwell sm_120).

The server runs **one dedicated tuned model**: **Qwen3.6-27B with Multi-Token Prediction (MTP)**,
served under the API id **`qwen3.6-27b-mtp`**. MTP is a self-speculative decoding mode (a draft head
baked into the GGUF) that gives ~1.4–2.2x faster generation with no quality loss; it requires a single
request stream (`--parallel 1`), so the box serves exactly one model.

The service is launched by `/opt/llama.cpp/run-server.sh` from `/etc/llama-server.env`
(see `setup-llama-cpp.sh`). The previous 5-model router was retired — see
`docs/llama-cpp-build.md` for the build/perf rationale, and `presets/README.md` for the rollback path.

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

Expected output:
```
"qwen3.6-27b-mtp"
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

### Swapping the model later

Single-model mode has no on-the-fly router. To change the model, update
`/etc/llama-server.env` and restart — use `switch-model.sh` on the box:

```bash
ssh pedrogpt
./switch-model.sh download unsloth/Qwen3.6-27B-MTP-GGUF "*UD-Q4_K_XL*" /opt/models/qwen3.6-27b-mtp
./switch-model.sh /opt/models/qwen3.6-27b-mtp/Qwen3.6-27B-MTP-UD-Q4_K_XL.gguf qwen3.6-27b-mtp
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

## Replacing the model

Single-model mode has no router. To change the served model, swap it in
`/etc/llama-server.env` and restart — `switch-model.sh` does both (run it on the box):

```bash
ssh soypete@100.121.229.114
# download a new GGUF (prefer an MTP variant for the free speedup)
./switch-model.sh download <org>/<model>-GGUF "*UD-Q4_K_XL*" /opt/models/<model-name>
# activate it (path + API alias); MTP is auto-disabled for non-MTP GGUFs
./switch-model.sh /opt/models/<model-name>/<file>.gguf <api-alias>
```

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

### Roll back to the old router (5-model) mode

The router mechanism is retired but recoverable: restore a `--models-preset` drop-in at
`/etc/systemd/system/llama-server.service.d/preset.conf` pointing at `presets/all-models.ini`,
`daemon-reload`, and restart. See `presets/README.md` and `git log` for the prior config. Note MTP
cannot run in router mode (`--parallel 1` only), so rolling back trades the MTP speedup for
multi-model switching.

### Check Prometheus metrics

```bash
curl http://100.121.229.114:8000/metrics | grep -E 'llama_|requests_'
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
| `/opt/llama.cpp/run-server.sh` | launcher wrapper (reads the env file, assembles MTP/KV flags) |
| `/opt/models/qwen3.6-27b-mtp/` | the MTP GGUF |
| `/etc/systemd/system/llama-server.service` | systemd unit (runs `run-server.sh`) |
| `/etc/llama-server.env` | runtime config: `MODEL`, `MODEL_ALIAS`, `SPEC_TYPE`, `N_CTX`, sampling, etc. |
| `scripts/pedrogpt/presets/all-models.ini` | rollback/reference INI for router mode (not used live) |
