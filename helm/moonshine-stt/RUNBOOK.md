# Moonshine STT — Runbook

Self-hosted speech-to-text for Open WebUI. Moonshine v2 behind a small
OpenAI-compatible API, CPU-only.

| | |
|---|---|
| Namespace | `moonshine` |
| Helm release | `moonshine-stt` (chart `helm/moonshine-stt`) |
| Service | `moonshine-stt.moonshine.svc.cluster.local:8000` |
| Image | `100.81.89.62:5000/moonshine-stt:0.1.0` (built from `docker/moonshine-stt/`) |
| Model | `small-streaming` (English), baked into the image |
| Consumer | Open WebUI, via `AUDIO_STT_*` env in `helm/openwebui/values.yaml` |

## Architecture

Moonshine ships no server, and Open WebUI speaks the OpenAI audio API, so
`docker/moonshine-stt/app.py` is the adapter between them:

- `POST /v1/audio/transcriptions` — OpenAI multipart shape. Accepts
  wav/mp3/ogg/webm/m4a and transcodes to 16 kHz mono via ffmpeg before
  inference. Supports `response_format=json` (default) and `text`. Fields
  Moonshine cannot honour (`prompt`, `temperature`, `timestamp_granularities`)
  are accepted and ignored rather than erroring — clients send them routinely.
- `GET /healthz` — 200 only after the model is resident; 503 while loading.
  Both probes point here, so traffic never reaches a cold pod.
- `GET /v1/models` — some OpenAI clients probe this first.

Inference is serialised behind an `asyncio` lock (Moonshine is not documented
thread-safe) and the container runs a single uvicorn worker. **Scale with
replicas, not workers.**

## Measured performance

Measured on this cluster, 5.40 s of speech, `small-streaming`:

| CPU limit | RTF | Wall clock |
|---|---|---|
| 2 cores | **1.00 – 1.73** | 5.4 – 9.3 s |
| 3 cores (current) | **0.53 – 0.74** | 2.9 – 4.0 s |

RTF tracks the CPU limit almost linearly — a single transcription pegs the
limit, so the pod is throttle-bound, not memory-bound. At `cpu: 2` transcription
took *as long as the audio itself*; `cpu: 3` is roughly 2× faster and comfortably
faster than realtime.

For reference, the same clip on an M-series Mac (emulated amd64) hit RTF 0.068 —
about 20× faster than these nodes. **Do not size from a laptop measurement.**

Memory peaked at ~535 Mi against a 2 Gi limit, so memory has plenty of headroom.

Cold start: model load is well under a second (weights are local, not
downloaded), plus ~10-20 s for image pull and Python import on first schedule.
The readiness probe's `initialDelaySeconds: 20` covers this.

## Resource tuning

Start here before changing anything:

```bash
kubectl top pods -n moonshine          # is CPU pinned at the limit?
kubectl -n moonshine logs -l app.kubernetes.io/name=moonshine-stt \
  -c moonshine-stt | grep rtf=          # per-request RTF
```

- **CPU at the limit + RTF > 1** → raise `resources.limits.cpu`. Nodes `blue1`
  and `blue2` have 4 cores, `refurb` has 8, so going past 3 on the small nodes
  will starve other workloads.
- **Many concurrent users** → raise `replicaCount`. Each pod serialises its own
  inference, so concurrency comes from replicas.
- Memory is not the constraint at `small-streaming`; leave 1 Gi/2 Gi alone
  unless you move to `medium-streaming`.

## Bumping the model

The model is **baked into the image**, so `values.yaml` alone will not change
it — the env var only tells the app which baked model to load. Rebuild:

```bash
cd docker/moonshine-stt
podman build --platform linux/amd64 \
  --build-arg MOONSHINE_MODEL=medium-streaming \
  -t 100.81.89.62:5000/moonshine-stt:0.2.0 .
podman push --tls-verify=false 100.81.89.62:5000/moonshine-stt:0.2.0
```

Then update `helm/moonshine-stt/values.yaml`:

```yaml
image:
  tag: "0.2.0"
model:
  name: medium-streaming
modelCacheSizeLimit: 1Gi     # medium is larger than small's ~160Mi
```

Valid `model.name` values (from `moonshine_voice.ModelArch`): `tiny`, `base`,
`tiny-streaming`, `base-streaming`, `small-streaming`, `medium-streaming`.
Accuracy/size tradeoff: tiny 34M/12.0% WER, small 123M/7.84% WER,
medium 245M/6.65% WER. **Medium will roughly double RTF — re-measure before
committing to it on these CPUs.**

Then `helm upgrade moonshine-stt helm/moonshine-stt -n moonshine` and re-run
the smoke test below.

## Smoke test

```bash
kubectl -n moonshine port-forward svc/moonshine-stt 8899:8000 &
curl -s http://localhost:8899/healthz
# {"status":"ok","model":"small-streaming","language":"en"}

say --data-format=LEI16@16000 --channels=1 -o /tmp/t.wav "testing one two three"
curl -s -F "file=@/tmp/t.wav" http://localhost:8899/v1/audio/transcriptions
# {"text":"Testing one two three"}
```

End-to-end through Open WebUI's own code path:

```bash
kubectl -n openwebui exec deploy/openwebui-open-webui -c open-webui -- python -c "
import asyncio, types
from open_webui.routers.audio import transcribe
class App: state = types.SimpleNamespace()
class Req:
    app = App()
    def __init__(self): self.state = types.SimpleNamespace()
asyncio.run(transcribe(Req(), '/tmp/speech.webm', {}, None))"
```

## Open WebUI wiring

Set in `helm/openwebui/values.yaml` (Helm-managed — do not `kubectl edit`):

```yaml
AUDIO_STT_ENGINE=openai
AUDIO_STT_MODEL=small-streaming
AUDIO_STT_OPENAI_API_BASE_URL=http://moonshine-stt.moonshine.svc.cluster.local:8000/v1
AUDIO_STT_OPENAI_API_KEY=moonshine-local   # unused; service is unauthenticated
```

These env vars *seed* persisted config keys (`audio.stt.engine` etc). On this
cluster the upgrade did propagate to the stored config — verify after any
change:

```bash
kubectl -n openwebui exec deploy/openwebui-open-webui -c open-webui -- python -c "
import asyncio
from open_webui.config import Config
asyncio.run(Config.get('audio.stt.engine'))"
```

If a future upgrade does *not* propagate, set it in
**Admin → Settings → Audio** instead; the stored value wins over env.

## Known issues

### `refurb` cannot pull from the Zot registry

One replica lands on `refurb` and fails:

```
failed to pull ... http: server gave HTTP response to HTTPS client
```

`refurb` is missing `/etc/rancher/k3s/registries.yaml`; `blue1` and `blue2`
have it. This is a **node defect, not a chart problem** — it affects any
workload pulling from `100.81.89.62:5000`. Fix on the node:

```bash
# on refurb, as root
cat > /etc/rancher/k3s/registries.yaml <<'EOF'
mirrors:
  "100.81.89.62:5000":
    endpoint:
      - "http://100.81.89.62:5000"
configs:
  "100.81.89.62:5000":
    tls:
      insecure_skip_verify: true
EOF
systemctl restart k3s-agent
```

Until then the service runs with one healthy replica; scheduling still works
because `blue1`/`blue2` pull fine.

### Auth is not enabled

The service is unauthenticated inside the cluster and has no Ingress. If you
expose it, create a Secret out-of-band (the cluster has no External Secrets or
1Password operator — secrets are plain Opaque, created by script) and set:

```yaml
auth:
  existingSecret: moonshine-stt-auth
  secretKey: API_TOKEN
```

The chart never holds the token value. **Note the server does not yet enforce
the token** — `app.py` would need a dependency added to check it.

## Gotchas worth remembering

- **`readOnlyRootFilesystem` breaks model loading.** `moonshine-voice` uses
  `filelock` and writes a `.lock` beside each weight file even when only
  reading. An init container copies the baked cache to a writable `emptyDir`
  and `XDG_CACHE_HOME` points there. This did not reproduce locally under
  podman, which runs writable.
- Use `cp -r`, not `cp -a`, in that init container — preserving timestamps onto
  the emptyDir mount root fails with `Operation not permitted`.
- `Transcript.text` embeds `[0.00s]` timestamp prefixes. The app joins
  `line.text` instead so callers get clean prose.
- `helm ... --wait` on a slow rollout can exceed a 2-minute tool timeout and
  leave the release `pending-upgrade`, blocking further upgrades. Recover with
  `helm rollback`, or `helm uninstall` + reinstall if rollback also wedges.
- The package is **`moonshine-voice`** (MIT). `useful-moonshine` is the 2024
  package and PyPI `moonshine` is an unrelated project.
