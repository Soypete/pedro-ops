# Cluster Audit — 2026-08-03

Post-rebuild audit of the K3s cluster at `~/.foundry/kubeconfig`, covering drift vs. this repo,
backups, networking, secrets setup, and the redeploy worklist.

**Scope note:** read-only. No cluster mutations, no repo changes beyond this document.

---

## 0. The cluster is not the one this repo documents

The cluster was rebuilt ~4h before this audit. Node identity changed completely:

| | Documented (CLAUDE.md, README, architecture.md) | Actual |
|---|---|---|
| Control plane | 100.81.89.62 | **blue1 192.168.1.185** |
| Worker 1 | 100.70.90.12 | **blue2 192.168.1.97** |
| Worker 2 | 100.125.196.1 | **refurb 192.168.1.253** |
| VIP | 100.81.89.100 | **10.0.0.11** (unroutable from the LAN) |
| K3s | v1.28.x | **v1.36.2+k3s1** |

The cluster is now on the plain LAN (192.168.1.0/24). Tailscale is **entirely absent** —
no operator, no CRDs, no namespace, no ingressclass. Pod CIDR 10.42.0.0/16 and service
CIDR 10.43.0.0/16 do not conflict with the LAN.

**A redeploy was already in progress and stalled** before this audit finished: helm releases
`pedro` (ns `chatbot`) and `openbao-injector` (ns `openbao`) were installed at 14:56–14:57,
and the `redditwatch` namespace appeared minutes earlier. All are failing.

---

## 1. Critical findings

### 1.1 There is no backup, and nothing to restore from

`kubectl -n velero get backups` returns **no resources**. The `velero` S3 bucket is empty.
No Longhorn `backupvolumes` exist. **No recovery point exists for this cluster or its predecessor.**

Worse, the nightly schedule that does exist would not capture data even once it runs:

- `deployNodeAgent: false` → no node-agent DaemonSet → **kopia filesystem backup cannot run**
- CSI snapshot CRDs (`volumesnapshots.snapshot.storage.k8s.io`) are **not installed**
- Longhorn `backuptargets/default` has an **empty URL**, `available: false`; zero recurring jobs

The failure mode is the dangerous kind: the backup will report `Completed` while containing
**Kubernetes API objects only and zero volume data**.

Additionally, the backup destination (SeaweedFS) is a 50Gi Longhorn PVC **inside the same
cluster**, with all four SeaweedFS pods on `refurb`. There is no off-cluster copy of anything.
Losing `refurb` loses the primary data and the backup destination simultaneously.

**This is the highest-priority item in this document.**

### 1.2 Zot registry is up but empty — the hard blocker on redeploy

```
$ curl http://100.81.89.62:5000/v2/_catalog   →  {"repositories":[]}
$ curl http://192.168.1.185:5000/v2/_catalog  →  {"repositories":[]}
```

Zot is reachable on **both** the Tailscale and LAN addresses, so this is *not* a connectivity
problem. The registry's **storage did not survive the rebuild**. Every private image is gone.

Consequently every private-registry workload is in `ImagePullBackOff`:

| Namespace | Workload | Image |
|---|---|---|
| chatbot | pedro-twitch | `100.81.89.62:5000/pedro-twitch:fix-lo-db` |
| chatbot | pedro-keepalive | `100.81.89.62:5000/pedro-keepalive:df12033` |
| chatbot | pedro-mempalace | blocked — missing ServiceAccount |
| redditwatch | cfp-manual + 4 cronjobs | `100.81.89.62:5000/redditwatch:latest` |

**No amount of re-running Helm fixes this.** Images must be rebuilt and re-pushed first.

Secondary, unverified: pull errors read `Head "https://100.81.89.62:5000/..."` while Zot serves
plain HTTP, suggesting `/etc/rancher/k3s/registries.yaml` was lost in the rebuild. Could not be
confirmed — SSH to all three nodes was refused (publickey). **Verify this on the nodes yourself**,
or pushing images will not be sufficient.

### 1.3 There is no working ingress path into the cluster

`contour-envoy` is `type: ClusterIP` with a hardcoded `spec.externalIPs: [10.0.0.11]` and an
empty `status.loadBalancer`. There are **zero LoadBalancer services cluster-wide**. Envoy uses
no `hostNetwork`/`hostPort`, so no node binds :80/:443.

- `ping 10.0.0.11` → 100% loss (VIP is on `enp1s0`, off-LAN and unroutable)
- `curl http://192.168.1.185/` → connection refused

Every ingress has a blank ADDRESS. Grafana, Prometheus, Longhorn UI, and SeaweedFS are reachable
only via `kubectl port-forward`.

**And no TLS exists.** cert-manager is not installed despite `foundry/stack.yaml:30` declaring it
enabled. All five ingresses reference `*-tls` secrets that will never be created:

```
level=error msg="unresolved secret reference" secret=monitoring/grafana-tls
level=error msg="error identifying listener" error="no HTTPS listener configured"
```

> **Fix cert-manager BEFORE restoring the LB IP.** Otherwise Longhorn UI and the SeaweedFS S3
> endpoint — both unauthenticated admin surfaces — land on the LAN in cleartext.

### 1.4 SeaweedFS is split-brained — root cause of the Loki crashloop

The filer's metadata survived the rebuild; the volume server's data did not.

```
$ curl seaweedfs-master:9333/dir/status  →  "Volumes":0, "VolumeIds":" "
$ kubectl -n seaweedfs logs seaweedfs-s3-...
  volume 12 not found for fileId 12,41a35b10aca4
```

Every S3 GET for a pre-rebuild object returns HTTP 500. That is precisely why `loki-0` is in
`CrashLoopBackOff` (13 restarts):

```
init compactor: failed to init delete store: failed to get s3 object:
InternalError: We encountered an internal error, please try again. status code: 500
```

Purge the stale filer metadata (or recreate the `loki`/`velero` buckets) so the filer matches the
empty volume store. Loki will not start until this is resolved.

### 1.5 OpenBAO — CORRECTED: alive and healthy on 100.70.90.12

> **CORRECTION (same day).** The original finding below said OpenBAO's data was destroyed.
> **That was wrong.** OpenBAO is a *host-level* Foundry component (`foundry component list`
> shows it with no dependencies, like Zot) and it **survived the rebuild** on the old host:
>
> ```
> $ curl http://100.70.90.12:8200/v1/sys/health
> {"initialized": true, "sealed": false, "version": "2.0.0", ...}
> $ foundry component status openbao
> Healthy: true   Message: healthy (initialized, unsealed)
> ```
>
> The stored root token at `~/.foundry/openbao-keys/test/keys.json` authenticates
> successfully, and the `foundry-core/` KV mount is intact.
>
> The error was inferring destruction from the absent PVC — but OpenBAO never had a PVC,
> because it never ran in Kubernetes. Only the *injector* is in-cluster, and it points at
> `externalVaultAddr: http://100.70.90.12:8200`, which is correct and reachable.
>
> **What is still true:** only the injector is deployed in-cluster, `100.81.89.62:8200` is
> dead (that host is gone), and no in-cluster workload can currently use injection until the
> injector's config is confirmed against the surviving server.

<details>
<summary>Original (incorrect) finding, kept for the record</summary>

#### OpenBAO: keys survived, data did not — and it was never in-cluster

The assumption that OpenBAO is intact does not hold, though the conclusion is better than feared.

Evidence it is gone:
- No `openbao` PVC; only 5 PVCs exist cluster-wide
- All 5 PVs are `Bound` with reclaim policy **`Delete`** — no `Released`/`Retained` volume to re-bind
- No Longhorn backup, no Velero backup

The helm values reveal it was **never an in-cluster server**:

```yaml
server:   {enabled: false}
injector: {enabled: true, externalVaultAddr: "http://100.70.90.12:8200"}   # OLD cluster IP
```

`http://100.81.89.62:8200` is **dead**. Only the injector deployed, and it has no server to talk to.

**What survived:** `~/.foundry/openbao-keys/test/keys.json` (0600) holds `root_token`, 5 unseal
shares, threshold 3. **These do not help.** Unseal shares decrypt a storage backend that no longer
exists; a fresh OpenBAO comes up *uninitialized*, not sealed, and `bao operator init` mints an
entirely new share set.

**The real recovery path is 1Password**, which is the documented source of truth. This is
re-initialize-and-repopulate, not unseal-and-recover. Archive the old `keys.json` before anything
overwrites it.

</details>

**Do not act on the collapsed section above** — no re-initialization is needed. OpenBAO is
healthy and holds its existing data. Use `scripts/sync-openwebui-secrets-to-openbao.sh` to push
cluster secrets into it.

---

## 2. Storage — degraded and mis-documented

The 2TB drive is on **`refurb`**, not "Worker-1/blue2" as CLAUDE.md claims. It is the only bulk disk:

| Node | Disk | Capacity | Available |
|---|---|---|---|
| blue1 | default | 105 GB | 66 GB |
| blue2 | default | 105 GB | 74.8 GB |
| refurb | **data-disk-001** | **1622 GB** | 1311 GB |
| refurb | default | 105 GB | 34.4 GB |

Two volumes are permanently `degraded` with a single replica:

```
pvc-140c186f (prometheus 200Gi): ReplicaSchedulingFailure — "insufficient storage"
pvc-a5650a54 (loki 10Gi):        degraded, 1 running, 2 stopped
```

This is arithmetic, not misconfiguration: a 200Gi replica **cannot fit** on the 105GB nodes, and
`replica-soft-anti-affinity: false` requires distinct nodes. With `numberOfReplicas: 3`, replicas
2 and 3 are unschedulable forever. Either add bulk disks to blue1/blue2, shrink Prometheus
retention, or set `numberOfReplicas: 1` and document the volumes as single-copy.

**Dual-default StorageClass bug** — both are marked default:

```
local-path (default)   rancher.io/local-path
longhorn   (default)   driver.longhorn.io
```

Any PVC without an explicit `storageClassName` binds nondeterministically. **Fix before deploying
apps**, or workloads will land on non-replicated local-path storage by chance.

---

## 3. Services and redeploy worklist

### Currently running (infrastructure only)
k3s · contour+envoy · longhorn · kube-prometheus-stack · grafana · alertmanager · promtail ·
seaweedfs · velero · external-dns · kube-vip · coredns

### Missing — the redeploy list, in dependency order

| # | Component | Source | Blocked by |
|---|---|---|---|
| 0 | **Rebuild + push all Zot images** | build hosts | — **do this first** |
| 1 | **cert-manager** | `foundry/stack.yaml:30` (declared, not installed) | — |
| 2 | **SeaweedFS metadata purge** | — | unblocks Loki + Velero |
| 3 | **OpenBAO server + init + repopulate from 1Password** | `foundry component install openbao` | — |
| 4 | **Tailscale operator** (if being kept) | `scripts/phase4-install-tailscale.sh` | TS OAuth creds |
| 5 | **CNPG operator** | undeclared prerequisite | — |
| 6 | pedro-bots / **iam_pedro** | `~/code/pedro/iam_pedro/charts/pedro-bots` | #0, #3, llama.cpp |
| 7 | pedro-embed-server | `helm/pedro-embed-server/` | — (public image) |
| 8 | OpenWebUI + Postgres | `helm/openwebui/`, `k8s/openwebui/postgres.yaml` | #5, #2 |
| 9 | redditwatch / pedro-agents | `~/code/pedro/pedro-bots/charts/pedro-agents` | #0 |
| 10 | Tailscale ingresses | `k8s/tailscale/`, `helm/tailscale-ingresses/` | #4 |

### iam_pedro — located

**Not in this repo.** It is a separate Go repo at **`~/code/pedro/iam_pedro`** (Twitch/Discord LLM
bot: llama.cpp + langchain-go + Supabase).

- Chart: `~/code/pedro/iam_pedro/charts/pedro-bots`, release **`pedro`**, namespace **`chatbot`**
- Components: `pedro-twitch`, `pedro-discord`, `pedro-keepalive`, `pedro-mempalace`
- **Already installed** (rev 1, 14:56) and failing on the empty registry
- Deploy docs: `~/code/pedro/iam_pedro/deployment/README.md`

Do not confuse it with the sibling `~/code/pedro/pedro-bots` — a *different* (Python/Reddit) repo
that feeds the `redditwatch` namespace.

### External dependencies

| Target | Status |
|---|---|
| pedrogpt vLLM `100.121.229.114:8000` | **UP** (HTTP 200) |
| pedrogpt llama.cpp `100.121.229.114:8080` | **DOWN** — all pedro-bots point here |
| Zot `100.81.89.62:5000` | up, **catalog empty** |
| OpenBAO `100.81.89.62:8200` | **DOWN** |
| PowerDNS `100.81.89.62:8081` | up (401), external to cluster, unmanaged |

### Known config bugs to fix while redeploying

- `k8s/monitoring/grafana-values.yaml:44` — Loki datasource points at
  `loki-gateway.monitoring.svc` but Loki now lives in ns `loki`. **Dangling datasource.**
- `helm/openwebui/values.yaml:48` — SeaweedFS port `8332`; the live service port is **8333**.
- pedro-bots expects embeddings at `pedro-embeddings.chatbot:8081`, but the chart names the
  service `pedro-embed-server`. **Name mismatch** — set `fullnameOverride` or fix the env var.
- `chatbot/pedro-mempalace` — `serviceaccount "pedro-mempalace" not found`.
- `scripts/k8s/k3s-config-blue1.yaml:9` hardcodes `node-ip: 192.168.1.128`; blue1 is **.185**.
  `scripts/k8s/coredns-configmap.yaml:31-32` has the same stale IPs. **Running
  `scripts/k8s/apply-cluster-config.sh` as-is would break the cluster.**
- `scripts/backup-openwebui-pg.sh` cannot run — it creates `VolumeSnapshot` resources whose CRDs
  are not installed. `docs/maintenance.md:23-56` documents this non-functional path as *the*
  Postgres backup procedure.

---

## 4. Secrets — how they are actually wired

Three inconsistent patterns coexist:

**A. OpenBAO injector annotations — inert.** Pods in `chatbot`/`redditwatch` carry
`vault.hashicorp.com/agent-inject` annotations, but no injector webhook exists
(`mutatingwebhookconfigurations` shows only prometheus + longhorn). No `vault-agent` sidecar is
ever created. Fails silently as an app-level auth error much later.

**B. Plain K8s Secrets via `envFrom`/`secretKeyRef` — what actually works today.**
`chatbot/pedro-secrets` (5 keys), `redditwatch/redditwatch-secrets` (9 keys). These are created
out-of-band: **no script in the repo creates them.** `docs/architecture.md:295` references
`scripts/create-secrets-from-openbao.sh`, which **does not exist**. The OpenBAO → K8s Secret leg
of the documented pipeline is unimplemented — which is why these cannot be reproduced after a rebuild.

**C. Foundry vars** — `~/.foundryvars` via `scripts/setup-tailscale-secrets.sh`.

Not used anywhere: External Secrets Operator, Sealed Secrets, SOPS, age.

### Security issues

- **PowerDNS API key is a plaintext container arg** on the live external-dns deployment
  (`--pdns-api-key=797c637e...`), readable by anyone with pod-get, sent over plain HTTP to a
  still-live server. `foundry/stack.yaml:21` uses `${secret:dns:api_key}` correctly; the deployed
  manifest does not honor it. **Rotate it.**
- **`~/.foundry/stack.yaml` holds plaintext S3 credentials** in ~5 places, one key pair reused
  across Loki, SeaweedFS, and Velero — so Loki's credentials can delete every Velero backup.
  Outside the repo, so not a git leak, but unencrypted on disk. Rotate and split.
- **`k8s/openwebui/postgres.yaml:29` commits a plaintext Postgres superuser password to git.**
  Violates the CLAUDE.md "never commit secrets" rule.
- A live GitHub OAuth client ID is in the **uncommitted** `docs/secrets-playbook.md:250` diff.
  Low severity (client IDs are semi-public) but placeholder it before committing.
- `keys.json` holds all 5 unseal shares **and** the root token in one file — a single-file
  compromise is a full vault compromise, defeating the purpose of Shamir splitting.

**History is clean:** `git log --all -- secrets/` shows only `README.md` and
`secrets-map.yaml.example` were ever committed. No real secret is in git history.

---

## 5. Stale documentation

`docs/cluster-state.md` is the newest commit yet entirely wrong: it lists 17 namespaces
(including `tailscale`, `openbao`, `openwebui`, `kei`, `pedro`, `pedrotag`, `cnpg-system` — none
exist) against an actual 13, and swaps the blue2/refurb IPs.

Wrong node IPs/VIP: `CLAUDE.md:31-34`, `README.md:26-30`, `docs/architecture.md:31-33,48-50`,
`docs/cluster-state.md:11-13`, `docs/tailscale-setup.md:60,67-68`, `docs/troubleshooting.md`
(~13 `ssh root@100.x` commands).

Claims contradicted by reality:
- `CLAUDE.md:44` — PowerDNS serves `soypetetech.local` → **NXDOMAIN**, no stub in the Corefile
- `CLAUDE.md:45-46` — Tailscale operator + split DNS → neither exists
- `CLAUDE.md:39-42` — 2TB drive on Worker-1 at `/data/persistent-storage` → it is on `refurb`,
  and Longhorn uses `/var/lib/longhorn`
- `CLAUDE.md:40` — "2 replicas" → configured for 3
- `CLAUDE.md:97-99`, `README.md:96-99` — `kubectl apply -k k8s/base` / `k8s/overlays/production`
  → **neither directory exists**; there are no `kustomization.yaml` files anywhere despite
  `CLAUDE.md:117` mandating Kustomize
- `CLAUDE.md:218-221` — references `docs/tailscale-integration.md`, which **does not exist**
- `README.md:240-246` + `k8s/monitoring/README.md:136` — `scripts/backup-cluster.sh` and bucket
  `s3://pedro-ops-backups/` → **neither exists**
- `README.md:38,41` — Loki 100Gi / SeaweedFS 500Gi → actually 10Gi / 50Gi

Also stale: `foundry/stack.yaml` `setup_state.openbao_installed/initialized: true` persists across
rebuilds and will lie to Foundry on reinstall.

`k8s/monitoring/persistent-volumes.yaml` declares local-storage PVs pinned to a node named
`worker-1` that has never existed in this cluster. **Recommend deleting** — actively misleading.

---

## 6. Recommended order of operations

1. **Verify `/etc/rancher/k3s/registries.yaml` on all three nodes** (I could not — SSH refused).
2. **Rebuild and push all Zot images.** Nothing app-level works until the catalog is non-empty.
3. **Fix the dual-default StorageClass** before creating any new PVCs.
4. **Install cert-manager**, then re-scope the kube-vip pool to a free 192.168.1.x range and
   convert `contour-envoy` to `type: LoadBalancer`. Order matters — TLS first.
5. **Purge SeaweedFS filer metadata** → unblocks Loki and Velero.
6. **Fix backups properly**: `deployNodeAgent: true`, `defaultVolumesToFsBackup: true`, install CSI
   snapshot CRDs, set a Longhorn backup target, and **add an off-cluster destination**. Then take a
   backup and *test a restore* — an untested backup is a hypothesis.
7. **Re-init OpenBAO** and repopulate from 1Password; set the PV reclaim policy to `Retain` first.
8. Redeploy apps in the dependency order in §3.
9. Rotate the PowerDNS key and the shared S3 credentials.
10. Update the docs in §5 — or delete them. Documentation describing a nonexistent recovery path
    is worse than none, because it will be trusted during an incident.
