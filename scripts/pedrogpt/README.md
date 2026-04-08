# pedrogpt Operations Guide

Runtime operations for the llama-server on pedrogpt (100.121.229.114, RTX 5090).

The server runs in **router mode**: all 5 models are registered, one loads at a time.
Callers switch models by setting `"model"` in the API request — no service restarts needed.

---

## Endpoints

Base URL: `http://100.121.229.114:8080`

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Server health — returns `{"status":"ok"}` when ready |
| `/v1/models` | GET | List all registered models |
| `/v1/chat/completions` | POST | OpenAI-compatible chat completions |
| `/metrics` | GET | Prometheus metrics |

### Check health

```bash
curl http://100.121.229.114:8080/health
```

### List registered models

```bash
curl http://100.121.229.114:8080/v1/models | jq '.data[].id'
```

Expected output:
```
"gpt-oss-20b"
"nemotron-3-super-120b"
"qwen3-next-80b"
"qwen3-coder-30b"
"qwen2.5-vl-32b"
```

---

## Switching Models via API

Set `"model"` to any registered model name. The server unloads the current model and
loads the requested one (~30s swap time on first request).

```bash
# General chat / reasoning (default, loads on startup)
curl http://100.121.229.114:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-oss-20b",
    "messages": [{"role": "user", "content": "explain recursion"}],
    "max_tokens": 500
  }'

# Heavy reasoning
curl http://100.121.229.114:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "nemotron-3-super-120b", "messages": [{"role": "user", "content": "solve this step by step..."}], "max_tokens": 1000}'

# Coding (large context, MoE expert offload)
curl http://100.121.229.114:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen3-next-80b", "messages": [{"role": "user", "content": "write a Go HTTP server"}], "max_tokens": 500}'

# Coding (lighter, faster)
curl http://100.121.229.114:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen3-coder-30b", "messages": [{"role": "user", "content": "write a Go HTTP server"}], "max_tokens": 500}'

# Vision (pass image as base64 or URL)
curl http://100.121.229.114:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-vl-32b",
    "messages": [{
      "role": "user",
      "content": [
        {"type": "text", "text": "what is in this image?"},
        {"type": "image_url", "image_url": {"url": "https://example.com/image.jpg"}}
      ]
    }],
    "max_tokens": 300
  }'
```

> **Note:** gpt-oss-20b and nemotron are reasoning models. They produce `reasoning_content`
> internally before outputting `content`. Use `max_tokens >= 500` to get a complete response.

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
| `model not found` | Wrong model name in API request | Use exact section names from INI (e.g. `gpt-oss-20b`) |
| `--flash-attn: expected value` | Old flag syntax | Use `--flash-attn on` in drop-in |
| Empty `content`, has `reasoning_content` | Reasoning model hit token limit | Increase `max_tokens` |
| CUDA forward compat warning | Non-fatal driver mismatch warning | Ignore — model still loads on CPU or GPU |
| Model swap hangs >60s | Previous model didn't unload | Restart service: `sudo systemctl restart llama-server` |

### Inspect the active systemd config

```bash
ssh soypete@100.121.229.114 "systemctl cat llama-server"
```

### Check which model is loaded

```bash
curl http://100.121.229.114:8080/v1/models | jq '.data[] | select(.meta.n_ctx_train) | {id, loaded: true}'
```

---

## Adding a New Model

1. **Find the model** — check [LiveBench](https://livebench.ai) for scores, find GGUF on HuggingFace
   (prefer `unsloth` or `bartowski` repos, `UD-Q4_K_XL` for MoE, `Q4_K_M` for dense)

2. **Download to pedrogpt:**

```bash
ssh soypete@100.121.229.114
~/.local/bin/hf download <org>/<model>-GGUF \
  --include "*Q4_K_M*" \
  --local-dir ~/models/<model-name>
sudo mv ~/models/<model-name> /opt/models/
```

3. **Add a section to `presets/all-models.ini`:**

```ini
[my-new-model]
model = /opt/models/my-new-model/my-new-model-Q4_K_M.gguf
ctx-size = 16384
```

4. **Deploy the updated INI:**

```bash
scp scripts/pedrogpt/presets/*.ini soypete@100.121.229.114:/tmp/
ssh soypete@100.121.229.114 "sudo mv /tmp/*.ini /opt/llama.cpp/presets/ && sudo chmod 644 /opt/llama.cpp/presets/*.ini"
```

5. **Restart the service:**

```bash
ssh soypete@100.121.229.114 "sudo systemctl restart llama-server"
```

6. **Verify it's registered:**

```bash
curl http://100.121.229.114:8080/v1/models | jq '.data[].id'
```

---

## Maintenance

### Restart the service

```bash
ssh soypete@100.121.229.114 "sudo systemctl restart llama-server"
```

### View the drop-in override

```bash
cat /etc/systemd/system/llama-server.service.d/preset.conf
```

### Rollback to single-model mode

```bash
ssh soypete@100.121.229.114
sudo rm /etc/systemd/system/llama-server.service.d/preset.conf
sudo systemctl daemon-reload
sudo systemctl restart llama-server
```

### Check Prometheus metrics

```bash
curl http://100.121.229.114:8080/metrics | grep -E 'llama_|requests_'
```

### GPU memory usage

```bash
ssh soypete@100.121.229.114 "nvidia-smi --query-gpu=memory.used,memory.free,memory.total --format=csv"
```

---

## Files

| Path | Description |
|------|-------------|
| `/opt/llama.cpp/` | llama.cpp build |
| `/opt/llama.cpp/presets/all-models.ini` | Active model roster |
| `/opt/models/` | Downloaded GGUF model files |
| `/etc/systemd/system/llama-server.service` | Base systemd unit |
| `/etc/systemd/system/llama-server.service.d/preset.conf` | Drop-in override (router mode) |
| `/etc/llama-server.env` | Runtime env vars (PORT, N_PARALLEL) |
| `scripts/pedrogpt/presets/` | Source INI files (deploy from here) |
