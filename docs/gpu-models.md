# GPU inference: models, endpoints, and swapping

Two inference backends sit behind the tailnet. This page is the single place for
what runs where, how to reach it, and how to change models. Deep operational detail
lives in the linked runbooks.

## Backends

| Backend | Hardware | Runtime | Models | Context |
|---|---|---|---|---|
| **pedrogpt** | RTX 5090, 32GB VRAM | llama.cpp router mode | `qwen3.6-27b-mtp`, `qwen3.8-27b` | 216064 / 262144 (native max) |
| **spark-f5ea** | 2x DGX Spark, 128GB each (tp=2 over QSFP) | vLLM via `eugr/spark-vllm-docker` recipes | one large MoE at a time | recipe-defined, 500000 for the DeepSeek and GLM recipes |

**Planned on-demand additions to pedrogpt** (drafted in `presets/router.ini`, not
deployed). llama.cpp must be rebuilt past b9802 first: Glimmer needs b10353+, and
Lightning and Gemma 4 are unverified on b9802:

| API id | Model | Why |
|---|---|---|
| `muse-glimmer-30b` | Muse Glimmer 30B (dense) | strongest agentic/coding scores of the 5090 candidates |
| `nemotron-3.5-lightning` | Nemotron 3.5 Lightning 30B-A3B | fastest output and long-document latency |
| `gemma-4-26b-a4b-it` | Gemma 4 26B-A4B (MoE, ~4B active) | fast Gemma (~249 tok/s on the article's 5090 run); ctx 131072 |
| `gemma-4-31b-it` | Gemma 4 31B it (dense) | best long-context accuracy; tightest VRAM fit (ctx 65536 until measured) |
| `clef` | Clef 27B decision model (ggml-org) | question/option scoring via `/v1/systemone`; needs llama.cpp PR #29831; Q8_0 is 28.7 GB so it only fits at small ctx |

Source for the speed and benchmark figures: atomic.chat's RTX 5090 guide, not measured
on this box.

**Editor configs:** Nemotron 3.5 Lightning and both Gemma 4 models are listed in the
OpenCode and Pi configs (dotfiles) for coding trials. Muse Glimmer and Clef are documented
here only; Clef is not a chat model (it serves `/v1/systemone`).

Both are single-resident: pedrogpt runs one model at a time (`--models-max 1`),
and the Sparks run one recipe at a time. These checkpoints do not share memory.

## Addressing: use MagicDNS names, not IPs

Tailscale IPs change when a node is re-registered (for example, moving tailnets).
Hardcoded IPs were the cause of the 2026-10 connection failures: the old
`100.121.229.x` and `100.87.122.x` addresses all timed out while the servers were
healthy.

| Host | Name | Current IP (2026-10-26) |
|---|---|---|
| pedrogpt | `pedrogpt` | 100.93.195.29 |
| Spark head | `spark-f5ea` | 100.94.89.57 |

- **From a tailnet client** (laptop, OpenCode, scripts): use the name,
  e.g. `http://spark-f5ea:8000/v1`, `http://pedrogpt:8000/v1`.
- **From a pod in the cluster**: CoreDNS cannot resolve `ts.net`, so the name does
  not work there. Pod-facing config (`helm/openwebui`, `helm/observability`,
  `scripts/pedrogpt/llama-cpp-scrapeconfig.yaml`) needs the IP, or a Service that
  fronts the Tailscale egress proxy. **When a node is re-registered, update these.**

Quick check after any Tailscale change:

```bash
tailscale status | grep -E 'pedrogpt|spark'
for h in pedrogpt spark-f5ea; do curl -s -m 5 -o /dev/null -w "$h %{http_code}\n" http://$h:8000/v1/models; done
```

## Swapping models on the Sparks

Upstream `eugr/spark-vllm-docker` ships a recipe per model in `recipes/*.yaml`.
A recipe carries the container, env, mods and serve flags, so a swap is just
"stop the current recipe, start another". A `git pull` in `~/spark-vllm-docker`
brings recipe fixes.

Recipes of interest (see `./run-recipe.sh --list` for the full set):

| Recipe | Notes |
|---|---|
| `deepseek-v4-flash-0731` | current default; 284B MoE, ~167GB, tp=2, 500k ctx |
| `glm-5.3-flash` | candidate; `nvidia/GLM-5.3-Flash-FP4-Local`, 320B/18B-active MoE, ~166GiB, tp=2, 500k ctx, MTP, B12X container (experimental) |
| `minimax-m2-awq` | known-good fallback, weights cached |
| `deepseek-v4.1-flash` | **3x/4x Spark clusters only**: 510GB FP8, does not fit 2 nodes |

Swap procedure (on spark-f5ea):

```bash
sudo systemctl stop vllm-cluster
sudo vi /etc/default/vllm-cluster        # change START_SCRIPT (see vllm-cluster.env.example)
sudo systemctl start vllm-cluster
```

Each `START_SCRIPT` is a thin wrapper around `./run-recipe.sh <recipe> -n <nodes>`.
For a new model, copy `start-cluster-deepseek.sh`, change `RECIPE`, and scp it to
`/home/soypete/`. The scripts and `RUNBOOK.md` live in the dotfiles repo
(`spark-vllm/`).

First time on a new recipe, run `./run-recipe.sh <recipe> --setup`: it builds the
container and downloads and distributes the weights. Check disk first and reclaim
space on both nodes if needed:

```bash
./hf-download.sh --list -c               # models and sizes per node
./hf-download.sh --cleanup -c            # drop unreferenced revisions
```

After the swap, update the model id in the OpenCode provider entry. Recipes
that do not set `served-model-name` serve under the HF repo id
(e.g. `nvidia/GLM-5.3-Flash-FP4-Local`).

### Context is a tunable

500k is a ceiling, not a requirement. Lowering `max_model_len` in the recipe
frees KV memory, which can go to more concurrent sequences. Keep
`context + output` under the server's `--max-model-len`.

### Verify and roll back

```bash
curl -s http://spark-f5ea:8000/v1/models | jq '.data[].id'
cd scripts/pedrogpt/benchmark && go run . -url http://spark-f5ea:8000/v1 \
  -model nvidia/GLM-5.3-Flash-FP4-Local -n 10      # tok/s and TTFT
```

Rollback is the same swap: point `START_SCRIPT` back at the previous wrapper.
Cached weights stay on both nodes.

## Related

- `scripts/pedrogpt/README.md`: pedrogpt operations (router mode, presets)
- `scripts/pedrogpt/presets/README.md`: llama.cpp flag mapping
- `docs/tailscale-setup.md`: Tailscale operator and ACL
- dotfiles `spark-vllm/RUNBOOK.md`: Spark start/restart, QSFP, troubleshooting
