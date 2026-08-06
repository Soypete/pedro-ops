# Pedro Agents Deployment

LLM-powered agents that monitor Reddit, suggest topics, post to social, and
watch for conference CFPs. Source and chart live in
[`pedro-bots`](https://github.com/Soypete/pedro-bots), not this repo.

- **Namespace**: `redditwatch`
- **Helm release**: `pedro-agents` (chart `charts/pedro-agents` in pedro-bots)
- **Image**: `100.81.89.62:5000/redditwatch:latest`
- **Deployed**: 2026-08-06

## What runs

Four CronJobs, all times UTC:

| CronJob | Schedule | Purpose |
|---------|----------|---------|
| `pedro-agents-monitor` | `0 14,19,0 * * *` | Fetch + classify Reddit posts, digest to Discord |
| `pedro-agents-suggest` | `0 15 * * 1` | Weekly subreddit/keyword suggestions |
| `pedro-agents-social` | `0 14 * * *` | Social posting |
| `pedro-agents-cfp` | `0 16 * * 2` | Search for conference CFPs, digest to Discord |

Schedules are Mountain Time expressed in UTC, so they shift by an hour
between MDT and MST. The comments in `values.yaml` note the alternates.

## Deploying

```bash
cd ~/code/pedro/pedro-bots
helm upgrade --install pedro-agents charts/pedro-agents -n redditwatch
```

Use `--reset-values` if a previous upgrade set overrides with `--set`;
otherwise Helm carries those forward and the chart defaults appear to be
ignored.

## Dependencies

- **Postgres** — `postgres.chatbot.svc.cluster.local`, database
  `pedro_agentware`. Tables are `rw_topics`, `rw_classifications`, `rw_cfps`
  in the `public` schema. Migrations live in `pedro-bots/migrations/` and can
  be applied with:
  ```bash
  kubectl exec -i -n chatbot postgres -- \
    psql -U postgres -d pedro_agentware -v ON_ERROR_STOP=1 -f - < migrations/00N_x.sql
  ```
- **llama.cpp** — `http://100.121.229.114:8000/v1` (Tailscale GPU box).
  Note **port 8000**, not 8080.
- **Secrets** — the `redditwatch-secrets` Secret in the namespace, holding
  the Reddit, Discord, Supabase, and `POSTGRES_URL` values.

## Secrets: Secret vs OpenBao

The chart supports both, selected by `vault.enabled`:

- `vault.enabled=false` (**default**) — reads the existing
  `redditwatch-secrets` Secret via `envFrom`.
- `vault.enabled=true` — OpenBao agent injection writes
  `/vault/secrets/{reddit,discord,supabase}`, which the container sources
  before starting.

Injection defaults to off because the `redditwatch` OpenBao role has not
been verified. The injector is running (`openbao-injector-agent-injector`
in the `openbao` namespace) and the pattern works for other apps, but an
unrecognised role leaves pods hanging on init rather than failing fast.
Verify the role exists before flipping this on.

## Known issue: image pulls

`imagePullPolicy` is `IfNotPresent` rather than `Always` because
`/etc/rancher/k3s/registries.yaml` is not applied to the nodes, so
containerd tries HTTPS against Zot's plain-HTTP endpoint and every pull
fails. See [zot-registry-guide.md](zot-registry-guide.md).

Consequence: **pushing a new image does not update the cluster.** Nodes keep
using their cached layer. Until `registries.yaml` is applied, deploying new
application code requires fixing the node config first.

## Checking on it

```bash
kubectl get cronjobs -n redditwatch
kubectl get jobs -n redditwatch --sort-by=.metadata.creationTimestamp | tail
kubectl logs -n redditwatch -l job-name=<job> --tail=50

# Trigger a run by hand
kubectl create job -n redditwatch manual-cfp --from=cronjob/pedro-agents-cfp
```

CFP runs are slow — the LLM call grows with each fetched page, and a full
5-iteration run takes roughly 20 minutes. `activeDeadlineSeconds` is 3600.
