# Manual Changes — 2026-08-03

Changes made by hand during the post-rebuild audit. Companion to
[`cluster-audit-2026-08-03.md`](./cluster-audit-2026-08-03.md).

Two kinds of change are recorded here:

- **Live cluster patches** — imperative `kubectl` changes that are NOT yet reflected in any
  declarative source, and will be lost on a rebuild unless the paired Foundry config change
  is applied.
- **Config changes** — edits to `~/.foundry/stack.yaml` and dotfiles that make the fix durable.

> `~/.foundry/stack.yaml` is **outside this git repo** and is therefore not version-controlled.
> The edits below exist only on this machine. Consider vendoring a sanitized copy into the repo
> (it currently contains plaintext S3 and PowerDNS credentials — see the audit doc §4).

---

## 1. Default StorageClass — `local-path` demoted

### Problem
Both `local-path` (k3s built-in) and `longhorn` were annotated
`storageclass.kubernetes.io/is-default-class: "true"`. With two defaults, a PVC that omits
`storageClassName` binds **nondeterministically** — a workload expecting replicated Longhorn
storage could silently land on single-node, non-replicated `local-path`.

### Live change applied
```bash
export KUBECONFIG=~/.foundry/kubeconfig
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

Result — `longhorn` is now the sole default:
```
NAME              PROVISIONER             DEFAULT
local-path        rancher.io/local-path   false
longhorn          driver.longhorn.io      true
longhorn-static   driver.longhorn.io      <none>
```

### Why the patch alone is not enough
`local-path` is owned by a **k3s Addon**, not by Helm or Foundry:
```
objectset.rio.cattle.io/owner-gvk:       k3s.cattle.io/v1, Kind=Addon
objectset.rio.cattle.io/owner-name:      local-storage
spec.source:  /var/lib/rancher/k3s/server/manifests/local-storage.yaml
```
k3s reconciles that manifest by checksum. The patch holds for now, but a k3s upgrade that
rewrites `local-storage.yaml` will restore `is-default-class: true` and reintroduce the bug.

### Durable fix — applied to `~/.foundry/stack.yaml`
```yaml
components:
    k3s:
        # NOTE: 'disable' REPLACES foundry's defaults (traefik, servicelb) rather than
        # appending, so both must be listed explicitly here.
        disable:
            - traefik
            - servicelb
            - local-storage
        installed: true
```

Two things worth knowing about this key:

- Foundry parses `disable` at `v1/internal/component/k3s/types.go:93` and it **overwrites** the
  built-in default `["traefik","servicelb"]` — omitting either would re-enable it.
- `local-storage` is a supported value (exercised in `v1/internal/component/k3s/types_test.go:77`).

**Foundry gap worth reporting upstream:** `storage.set_default: true` only sets `defaultClass`
on the *Longhorn* chart (`v1/internal/component/storage/install.go:453`). There is no code path
that unsets k3s's `local-path` default, so Foundry alone cannot produce a single-default cluster.
Disabling the k3s addon is the workaround.

### Not yet applied
The `disable` list only takes effect when k3s is reinstalled/reconfigured. The running cluster
still has the `local-storage` addon active — the live patch above is what is holding the line.
Applying it requires a k3s server config change and restart on `blue1`:
```bash
foundry component install k3s    # verify intent first; this touches the control plane
```

---

## 2. Zot registry — relocated onto persistent storage

### Problem
The registry catalog is empty after the rebuild:
```bash
$ curl http://100.81.89.62:5000/v2/_catalog   →  {"repositories":[]}
$ curl http://192.168.1.185:5000/v2/_catalog  →  {"repositories":[]}
```
Zot is **reachable on both addresses**, so this is not a connectivity fault — the registry's
**storage did not survive**. Every private image is gone, which is why all workloads in
`chatbot` and `redditwatch` are in `ImagePullBackOff`.

### Root cause
Zot is **not a Kubernetes workload**. Foundry runs it as a plain Docker container on the host
holding the `zot` role (`v1/internal/component/zot/install.go:155`):
```
docker run --name foundry-zot -p 5000:5000 \
  -v /var/lib/foundry-zot:/var/lib/zot \
  -v /etc/foundry-zot:/etc/zot/config.json ...
```
Default data dir is `/var/lib/foundry-zot` (`v1/internal/component/zot/types.go:94`) — the host
**root filesystem** of blue1. It has no PVC, so it is covered by neither Longhorn replication
nor Velero. Rebuilding the host wipes the registry.

### Durable fix — applied to `~/.foundry/stack.yaml`
```yaml
components:
    zot:
        installed: true
        storage:
            mount_path: /data/persistent-storage/zot
```
`storage.mount_path` overrides the container's data dir
(`v1/internal/component/zot/install.go:108-109`), placing image blobs on persistent storage
instead of the ephemeral host root.

> **Verify before applying.** The `zot` role is on **blue1**, but the audit found the 2TB disk
> (`data-disk-001`, 1.6TB) is on **refurb** — blue1 has only a ~105GB root disk. Confirm that
> `/data/persistent-storage` actually exists on blue1 and is backed by durable storage. If it is
> not, either move the `zot` role to `refurb` or point `mount_path` at a real persistent mount on
> blue1. Setting this to a path on the same ephemeral root disk fixes nothing.

### Still required — config alone does not restore images
Relocating storage prevents the *next* loss; it does not recover what is already gone. There is
no backup of the registry (see audit §1.1). **Every private image must be rebuilt and re-pushed:**

```bash
# example, per ~/code/pedro/iam_pedro/deployment/README.md
cd ~/code/pedro/iam_pedro && TAG=$(git rev-parse --short HEAD)
for SERVICE in discord twitch keepalive; do
  podman build --platform linux/amd64 -f cli/${SERVICE}/${SERVICE}Bot.Dockerfile \
    -t 100.81.89.62:5000/pedro-${SERVICE}:${TAG} .
  podman push --tls-verify=false 100.81.89.62:5000/pedro-${SERVICE}:${TAG}
done

curl -s http://100.81.89.62:5000/v2/_catalog   # must be non-empty before redeploying
```
Also needed: `pedro-mempalace`, `redditwatch`, and the `pedro-tag` images.

### Unverified — check this before assuming pushes are sufficient
Pull failures read `Head "https://100.81.89.62:5000/..."` (HTTPS) while Zot serves plain **HTTP**,
which suggests `/etc/rancher/k3s/registries.yaml` was lost in the rebuild. **This could not be
confirmed — SSH to all three nodes was refused (publickey).** Verify on each node:
```bash
cat /etc/rancher/k3s/registries.yaml
```
If absent, images will still fail to pull after being pushed. The repo has a template at
`scripts/k8s/registries.yaml`, but note it hardcodes the **old** Tailscale IPs and needs updating
to the current LAN addresses before use.

---

## 3. Dotfiles — KUBECONFIG and foundry PATH

### KUBECONFIG pointed at a nonexistent file
Two stale references, both corrected to `~/.foundry/kubeconfig`:

| File | Was | Now |
|---|---|---|
| `~/dotfiles/zsh/zsh_profile:7` | `~/.kube/pedro-ops-config` | `~/.foundry/kubeconfig` |
| `~/dotfiles/CLAUDE.md:81` | `~/kubeconfig` | `~/.foundry/kubeconfig` |

`~/dotfiles/zsh/zshrc:171` was already correct, which is why kubectl worked despite the above.

### foundry PATH — stale entry removed, duplicate collapsed
`~/dotfiles/zsh/zshrc:8` pointed at `$HOME/code/cli/foundry`, which **does not exist**. A second,
correct entry later in the file was masking the problem. Consolidated to one entry at the top:

```bash
# Foundry CLI -- built from source at ~/code/opensource/foundry/v1
# (rebuild: cd ~/code/opensource/foundry/v1 && go build -o foundry ./cmd/foundry)
export PATH="$HOME/code/opensource/foundry/v1:$PATH"
```
The duplicate at former line 171 was replaced with a pointer comment.

### foundry rebuilt from source
```bash
cd ~/code/opensource/foundry/v1 && go build -o foundry ./cmd/foundry
```
Note the module root is `v1/`, not the repo root — `go build ./...` from the repo root fails with
`directory prefix . does not contain main module`.

Verified in a fresh login shell:
```
$ zsh -lc 'which foundry && foundry --version && echo $KUBECONFIG'
/Users/soypete/code/opensource/foundry/v1/foundry
foundry version dev
/Users/soypete/.foundry/kubeconfig
```

---

## 3a. OpenWebUI stack — deployed and automated

Deployed the full OpenWebUI stack and captured every step in scripts, so a future rebuild does
not depend on anyone remembering the order.

### New scripts

| Script | Purpose |
|---|---|
| `scripts/setup-seaweedfs-buckets.sh` | Idempotently create the S3 buckets the stack needs (`loki`, `velero`, `openwebui`, `openwebui-pg`). Bucket creation was previously an undocumented manual step. |
| `scripts/deploy-openwebui.sh` | End-to-end OpenWebUI deploy in dependency order. Idempotent and safe to re-run. |
| `skaffold.yaml` | Declarative deploy profiles (`infra`, `openwebui`, `embed`). **Unvalidated** — skaffold is not installed on the admin machine. The scripts remain the source of truth. |

### What got deployed

```
openwebui-db-1                  1/1  Running   # CNPG primary
openwebui-db-2                  1/1  Running   # CNPG replica
openwebui-open-webui-*          1/1  Running
openwebui-open-webui-redis-*    1/1  Running
openwebui-pipelines-*           1/1  Running
openwebui-tika-*                1/1  Running
```

Verified: DB migrations ran (`Seeded 380 new config defaults`) and the app serves HTTP 200.

### Deployment method (answers "why isn't Postgres a Helm chart?")

- **Helm** — CNPG operator (`cnpg/cloudnative-pg`), OpenWebUI (`open-webui/open-webui`).
  Redis, Tika and pipelines are **subcharts** of open-webui, not separate releases.
- **kubectl** — `openwebui-db` is a **Cluster CR**, not a chart. CNPG's `cloudnative-pg` chart
  ships only the operator; databases are declared as CRs. This is also what
  `docs/maintenance.md:78` has always documented.

### Bugs found and fixed

| Issue | Detail |
|---|---|
| **Redis contradiction** | `redis.enabled: false` while `websocket.manager: redis` — websockets pointed at a Redis that was never deployed. Now `enabled: true`; the chart renders `openwebui-open-webui-redis`. |
| **S3 port wrong** | `values.yaml` used `seaweedfs-s3:8332`; the live service port is **8333**. Present since the original commit (`7d9f718`) — it never worked. Now uses the FQDN + 8333. |
| **Plaintext PG password in git** | `postgres.yaml:29` had the superuser password in `postInitSQL`. Replaced with `superuserSecret`, password rotated, and the line removed. |
| **Duplicate env vars** | `OLLAMA_BASE_URLS` / `ENABLE_OLLAMA_API` in `extraEnvVars` collided with values the chart sets from `ollama.enabled: false`, producing *"hides previous definition … may be dropped"*. Removed; the chart handles them. |
| **pgvector missing** | `postInitSQL` runs only on **first bootstrap**, so `CREATE EXTENSION vector` never applied. The image does ship pgvector (`vector 0.8.0`) — it just needed running. The script now does this idempotently. |
| **Superuser password mismatch** | The cluster bootstrapped **before** `superuserSecret` existed, so CNPG kept its bootstrap password and did **not** retroactively adopt the Secret. OpenWebUI crashlooped with `FATAL: password authentication failed for user "postgres"`. Fixed with `ALTER USER`; the script now detects and repairs this automatically. |

### SeaweedFS split-brain — partially resolved, one manual step outstanding

Recreating the `loki` bucket did **not** clear the fault. The bucket's *contents* survived:
`/buckets/loki/` still held `loki_cluster_seed.json`, 12 `index/` dirs and ~1605 `fake/` chunk
dirs, all referencing volumes (12, 14, …) that no longer exist — the volume server reports
`"Volumes":0`. Every read of those objects returns HTTP 500.

The underlying log data is **unrecoverable** regardless; only dead metadata remains.

**Outstanding manual step** (the delete was blocked as a destructive operation, deliberately —
run it yourself after confirming):

```bash
# Verify the data is genuinely orphaned first:
kubectl -n seaweedfs exec seaweedfs-filer-0 -- \
  sh -c "echo 'fs.meta.cat /buckets/loki/loki_cluster_seed.json' | weed shell" | grep volumeId
kubectl -n seaweedfs exec seaweedfs-master-0 -- wget -qO- http://localhost:9333/dir/status

# Then clear and recreate:
kubectl -n seaweedfs exec seaweedfs-filer-0 -- \
  sh -c "echo 's3.bucket.delete -name loki' | weed shell"
./scripts/setup-seaweedfs-buckets.sh loki
kubectl -n loki delete pod loki-0
```

Until this is done `loki-0` stays in CrashLoopBackOff on `init compactor: failed to get s3 object`.

### Still outstanding for OpenWebUI

- **No ingress.** `ingress.enabled: false` and Tailscale (the intended path) is gone. Access is
  `kubectl -n openwebui port-forward svc/openwebui-open-webui 8080:8080`.
- **No backups** for `openwebui-db` — tracked in [issue #13](https://github.com/Soypete/pedro-ops/issues/13).
- **Shared S3 credentials.** `openwebui-secrets` reuses the one key pair that Loki, Velero and
  SeaweedFS all share, so any component can delete another's objects. Read from
  `~/.foundry/stack.yaml` because no Kubernetes Secret holds them. Splitting into per-app
  least-privilege credentials is still TODO.
- **`WEBUI_SECRET_KEY` is generated** if absent. Save it to 1Password — losing it invalidates
  all sessions. There is no `openwebui` S3 item in 1Password today (only an `openweb ui` login).

---

## 3b. Tailscale operator — installed, blocked on expired OAuth credentials

The manifest for `https://ai.tail6fbc5.ts.net` **already existed** and is correct:
`k8s/tailscale/openwebui-ingress.yaml` targets `ai.tail6fbc5.ts.net` with backend
`openwebui-open-webui:8080`. It could not work because the operator was absent — there was no
`tailscale` IngressClass for it to bind to.

Installed the operator (`tailscale/tailscale-operator` into ns `tailscale`, credentials read
from 1Password items `TS_CLIENT_ID` / `TS_CLIENT_SECRET`). The CRDs and IngressClass registered
successfully:

```
NAME        CONTROLLER
tailscale   tailscale.com/ts-ingress
+ connectors, dnsconfigs, proxyclasses, proxygroups, recorders, tailnets .tailscale.com
```

**But the operator cannot authenticate.** It crashlooped with:

```
creating operator authkey: Post "https://controlplane.tailscale.com/api/v2/tailnet/-/keys":
oauth2: cannot fetch token: 401 Unauthorized
Response: {"message":"API token invalid"}
```

Verified independently against Tailscale's own endpoint — not a cluster or config problem:

```
$ curl -X POST https://api.tailscale.com/api/v2/oauth/token \
    -d client_id=... -d client_secret=...
HTTP 401
```

The stored OAuth credentials (last edited ~5 months ago) have been **revoked or expired**.

The operator Deployment was **scaled to 0** to avoid a permanent crashloop. CRDs and the
IngressClass remain installed, so applying the ingress manifests now would leave them pending
rather than failing admission.

### To finish

1. Mint new OAuth credentials at https://login.tailscale.com/admin/settings/oauth
   (scopes: `devices`, `auth_keys`; tag `tag:k8s-pedro-ops`).
2. Update the `TS_CLIENT_ID` / `TS_CLIENT_SECRET` items in the `pedro` 1Password vault.
3. Re-run:
   ```bash
   export TS_CLIENT_ID="$(op read 'op://pedro/TS_CLIENT_ID/credential')"
   export TS_CLIENT_SECRET="$(op read 'op://pedro/TS_CLIENT_SECRET/credential')"
   helm upgrade --install tailscale-operator tailscale/tailscale-operator -n tailscale \
     --set oauth.clientId="$TS_CLIENT_ID" --set oauth.clientSecret="$TS_CLIENT_SECRET"
   kubectl -n tailscale scale deploy operator --replicas=1
   kubectl apply -f k8s/tailscale/openwebui-ingress.yaml
   ```
4. Confirm the ingress gets an address, then browse to `https://ai.tail6fbc5.ts.net`.

Note the ACL policy in `k8s/tailscale/acl-policy.json` and the `Connector` /`DNSConfig` in that
directory also assume the pre-rebuild tailnet; re-check them once the operator authenticates.

---

## 3c. OpenBAO — correction: it survived, and now holds the OpenWebUI secrets

**The audit's original "OpenBAO is gone" finding was wrong**, and
`docs/cluster-audit-2026-08-03.md` §1.5 has been corrected. OpenBAO is a *host-level* Foundry
component (no k8s PVC by design) and it survived the rebuild:

```
$ curl http://100.70.90.12:8200/v1/sys/health
{"initialized": true, "sealed": false, "version": "2.0.0", "cluster_name": "vault-cluster-5896ff57"}

$ foundry component status openbao
Healthy: true   Message: healthy (initialized, unsealed)
```

The root token in `~/.foundry/openbao-keys/test/keys.json` authenticates, and the `foundry-core/`
KV mount is intact. **No re-initialization is needed.** The error was inferring destruction from
an absent PVC — but OpenBAO never had one, because it never ran in Kubernetes. Note the live
address is the *old* Tailscale IP `100.70.90.12`; `100.81.89.62:8200` is dead because that host
is gone.

### New script: `scripts/sync-openwebui-secrets-to-openbao.sh`

`WEBUI_SECRET_KEY` was generated at deploy time and existed **only** in a Kubernetes Secret —
losing it invalidates every OpenWebUI session. Same exposure for the Postgres superuser password.
These are cluster secrets, so they belong in OpenBAO.

The script reads the live k8s secrets and writes them to `foundry-core/apps/openwebui` and
`foundry-core/apps/openwebui-db`. It never reads values back out or prints them. Supports
`DRY_RUN=1`, which has been verified:

```
[dry-run] would write foundry-core/apps/openwebui    keys: WEBUI_SECRET_KEY,DATABASE_URL,AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY
[dry-run] would write foundry-core/apps/openwebui-db keys: username,password
```

**Not yet executed against OpenBAO** — the write uses the root token, so run it yourself:

```bash
export KUBECONFIG=~/.foundry/kubeconfig
./scripts/sync-openwebui-secrets-to-openbao.sh
```

Prefer a scoped token via `$VAULT_TOKEN` over the root token for routine use.

---

## 4. Validation performed

```bash
$ foundry config validate
✓ Configuration is valid: /Users/soypete/.foundry/stack.yaml
  Cluster: test (local)
  Hosts: 3
  Components: 15
```

Both `stack.yaml` edits parse cleanly. **Neither has been applied to the cluster yet** — they take
effect on the next `foundry component install` for k3s and zot respectively.

---

## 5. Outstanding — stale data in `stack.yaml`

Not changed, because correcting them affects how Foundry reaches the hosts and should be a
deliberate decision rather than a side effect of this cleanup:

- `hosts:` still lists the **dead Tailscale IPs** (`blue1: 100.81.89.62`, `blue2: 100.125.196.1`,
  `refurb: 100.70.90.12`). The cluster now lives on `192.168.1.185/.97/.253`. Note blue2 and
  refurb are also **swapped** relative to reality.
- `cluster.vip: 100.81.89.100` — the actual VIP is `10.0.0.11`.
- `setup_state.openbao_installed: true` and `openbao_initialized: true` — both false now; these
  will mislead Foundry into skipping initialization on reinstall.
- Plaintext S3 credentials (~5 occurrences, one key pair shared by Loki, SeaweedFS, and Velero)
  and the PowerDNS API key. Both should be rotated and moved behind the `${secret:...}`
  indirection that `stack.yaml` already uses for `dns.api_key`.
