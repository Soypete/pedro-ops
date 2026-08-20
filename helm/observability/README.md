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
