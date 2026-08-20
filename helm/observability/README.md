# Pedro Observability

This chart adds application, database, OpenBao, and pedrogpt monitoring to the
existing kube-prometheus-stack. It does not replace Prometheus or Grafana.

## Prerequisites

1. Store a Discord channel webhook in OpenBao without printing it:

   ```bash
   export VAULT_ADDR=http://100.70.90.12:8200
   vault kv put foundry-core/monitoring/discord webhook_url='<discord-webhook>'
   ```

2. Sync the Kubernetes Secret and deploy:

   ```bash
   ./scripts/sync-discord-alert-secret.sh
   ./scripts/deploy-observability.sh
   ./scripts/verify-observability.sh
   ```

3. On pedrogpt, install the host/GPU exporters from the repository copy:

   ```bash
   ./scripts/pedrogpt/setup-metrics-exporters.sh
   ```

   The NVIDIA container runtime requires `/usr/bin/nvidia-cuda-mps-control`.
   Install the driver-matched `nvidia-compute-utils` package before running the
   script if that binary is absent.

## pedrogpt runs a llama.cpp router — expect one llama target down

pedrogpt serves two models through llama.cpp's router with `--models-max 1`: only one
model is resident in VRAM at a time (two 27B Q4 models do not fit in 32GB), and the
other is evicted. Scrapes pass `autoload=false` so Prometheus cannot force-load ~18 GB
just to collect metrics, so **the idle model's target returns HTTP 400 and reads down.
That is normal steady state, not an outage.**

Consequences baked into this chart:

- `verify-observability.sh` requires only *at least one* `llama-cpp` target up, and
  prints e.g. `llama-cpp  1/2 up`.
- Alerting splits the two cases: `PedroTargetDown` deliberately excludes
  `job="llama-cpp"`, and `PedroLlamaCppDown` fires only when
  `sum by (instance) (up{job="llama-cpp"}) == 0` — i.e. the router process itself is
  gone, not merely a model swapped out. Router reachability is additionally covered by
  the `/health` blackbox probe.
- One ScrapeConfig is generated per entry in `.Values.pedrogpt.models`; adding a model
  is a values edit. Do **not** also apply
  `scripts/pedrogpt/llama-cpp-scrapeconfig.yaml` — it defines the same targets with the
  same labels, and running both double-counts every series in `sum()` queries.

## Coverage

- Native metrics: llama.cpp, OpenBao, Twitch, Discord, Slack, KEI ABAC/OIDC/web,
  CloudNativePG, and the infrastructure monitors already installed.
- Exporters: standalone PostgreSQL instances, Redis, pedrogpt host, and NVIDIA GPU.
- Blackbox probes: OpenWebUI, Pipelines, Tika, Moonshine, credential-admin, Zot,
  llama health, PostgreSQL, and Redis.
- Grafana: fleet, applications, databases, and GPT/GPU dashboards in the `Pedro`
  folder.

Secret values are referenced from existing Kubernetes Secrets or synced from
OpenBao. `helm template` output must never contain database passwords or the
Discord webhook.
