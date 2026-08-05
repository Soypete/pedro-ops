# Flannel API VIP misdirection and OpenWebUI outage — 2026-08-05

## Impact

OpenWebUI remained probe-healthy but authenticated requests intermittently
returned HTTP 500. WebSockets repeatedly failed to connect to Redis. The UI also
continued to report v0.10.2 after Helm reported app version 0.11.0.

## Root causes

1. blue1 advertised the Kubernetes API VIP `10.0.0.11` as its Flannel public
   endpoint. Workers advertised their physical LAN addresses. Cross-node pod
   traffic destined for blue1 therefore failed, including DNS requests from an
   OpenWebUI pod on refurb to CoreDNS on blue1.
2. OpenWebUI used the mutable image tag `latest` with `IfNotPresent`. Helm had
   upgraded to chart 16.0.0/appVersion 0.11.0, but the node reused a cached
   v0.10.2 image.
3. PostgreSQL was configured only as `PGVECTOR_DB_URL`; the primary
   `DATABASE_URL` was absent. Users, chats, and settings therefore lived in a
   SQLite database on the pod's ephemeral `EmptyDir` and disappeared whenever
   the pod was replaced.

The unhealthy Foundry PowerDNS recursor observed at the same time was separate
from Kubernetes `*.svc.cluster.local` resolution.

## Resolution

- Pinned blue1 to `node-ip: 192.168.1.185` and `flannel-iface: enp1s0`.
- Corrected the stale blue1 and blue2 LAN addresses in the cluster scripts.
- Pinned Helm chart `16.0.0` and OpenWebUI image `v0.11.0`.
- Connected both the primary application database and pgvector store to the
  existing PostgreSQL Secret.
- Replaced stale Whisper variables with the live Moonshine STT Service and its
  OpenAI-compatible `small-streaming` model.
- Restarted K3s on blue1 and verified all Flannel endpoints use `192.168.1.x`.
- Verified DNS and TCP connectivity from OpenWebUI to Redis and PostgreSQL by
  their Kubernetes Service names before rolling out OpenWebUI.

## Prevention

- Do not allow `10.0.0.11` to be selected as a node or Flannel endpoint; it is
  only the Kubernetes API VIP.
- Keep immutable application image tags and explicit Helm chart versions.
- Verify that `DATABASE_URL` is present in the rendered application container;
  `PGVECTOR_DB_URL` alone does not persist users, chats, or settings.
- When Kubernetes Service DNS fails, compare every node's `InternalIP` with its
  `flannel.alpha.coreos.com/public-ip` annotation before restarting CoreDNS.
