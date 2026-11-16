# Spark vLLM: troubleshooting and benchmarks

Quick triage for the two-node DGX Spark vLLM cluster (`spark-f5ea` head,
`spark-771e` worker, tp=2 over a QSFP link) and the benchmark numbers we have on
it. The full runbook, including every command referenced here, is dotfiles
`spark-vllm/RUNBOOK.md`.

## Symptom: `/v1/models` answers but chat requests hang

`/v1/models` (and `/health`) can answer while inference is dead, so test with a
real completion:

```bash
curl -s -m 60 http://spark-f5ea:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"nvidia/GLM-5.3-Flash-FP4-Local","messages":[{"role":"user","content":"say OK"}],"max_tokens":10}'
```

If that hangs, check the service and the QSFP link on the head node:

```bash
ssh spark-f5ea
sudo journalctl -u vllm-cluster -n 50 --no-pager
cat /sys/class/net/enp1s0f0np0/carrier      # 1 = link up, 0 = no physical link
ip addr show enp1s0f0np0                    # expect 192.168.100.10/24
ping -c 2 192.168.100.11                    # the worker over QSFP
```

`carrier=0` means the worker is down or the cable is out. `carrier=1` with no
address is a netplan problem instead. The runbook section
"Error: No active IB interfaces found." explains how to tell them apart; do not
run `netplan apply` for a `carrier=0` fault.

## Outage 2026-11-15: worker hung, QSFP link down

**Symptom.** `/v1/models` on spark-f5ea answered, but chat requests stalled.
`vllm-cluster.service` was in a restart loop on:

```
Error: Could not determine IP/CIDR for interface enp1s0f0np0
```

**Cause.** The QSFP link to spark-771e had no carrier: `carrier` read `0` and
`ip addr` showed no `192.168.100.10`. spark-771e was also unreachable on the LAN
(`192.168.1.84`); it had hung. Why it hung is **not verified**. The owner
suspected out-of-memory, but no evidence was collected.

**Fix (about 5 minutes once the worker is back).**

1. Power-cycle spark-771e. There is no BMC, so this is done at the box or its outlet.
2. On spark-f5ea, confirm the link before restarting anything:
   `carrier` = `1`, `192.168.100.10/24` on `enp1s0f0np0`, and
   `ping 192.168.100.11` answers.
3. Clean restart from `/home/soypete` on spark-f5ea:

   ```bash
   ./cleanup-containers.sh
   sudo systemctl restart vllm-cluster
   ```

4. Watch the journal. Weight load took 145 s, then warm-up; the model served
   again about 5 minutes after the restart. Run the curl above to confirm.

Journal lines of a healthy start, in order:

- `Detected Local IP: 192.168.100.10`
- `SSH to 192.168.100.11: OK`
- container image hash match between the nodes
- weights loaded, 91.99 GB per node
- model loading 83.62 GiB (vLLM's `Model loading took ...` line)

**Follow-up (not done).** To test the out-of-memory theory, capture on both nodes
while serving and after the next failure: `free -h`, `/proc/meminfo`, and
`dmesg | grep -i oom` (from the failed boot, via `journalctl -k -b -1`). Note
that GB10 unified memory makes `free` look nearly full on a healthy node; see the
runbook section "Only 5-6 GB free!". Earlier silent worker deaths were traced to
power loss, not memory (runbook: "spark-771e dies silently").

## Benchmarks: GLM-5.3-Flash-FP4 (2026-11-15)

Measured from a tailnet client with `scripts/spark-vllm-bench/` after the
restart above. Setup: `nvidia/GLM-5.3-Flash-FP4-Local` across both Sparks, MTP
speculative decoding with `num_speculative_tokens=5`. Other clients may have been
using the cluster at the same time, so **treat these as a lower bound**.

**Decode, single stream** (`decode_bench.py`: fixed prompt, 6 runs of 400 tokens)

| | |
|---|---|
| Median | **30.5 tok/s** |
| Min / max | 28.3 / 32.8 tok/s |
| TTFT (short prompt) | ~44 ms |

**Prefill** (`prefill_bench.py`: unique prompts, so the prefix cache cannot help)

| Prompt tokens | Prefill tok/s |
|---|---|
| ~3.0k | 1447 |
| ~9.3k | 1635 |
| ~22.3k | 1802 |
| ~44.3k | 1872 |

The first sizes include Triton JIT warm-up, so they read low.

**MTP acceptance during the decode runs** (from the vLLM journal)

| Draft position | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| Acceptance rate | 0.758 | 0.553 | 0.385 | 0.292 | 0.205 |

Average draft acceptance was 43.9%, about 3.2 tokens per verification pass.

**For comparison.** The runbook records ~64 tok/s single stream for
DeepSeek-V4-Flash-0731 on the same hardware (2026-08-31, 193 tokens). That was a
different model, a different measurement method, and possibly a quieter cluster,
so it is a reference point, not a like-for-like result.

### Hypotheses (not tested)

- **Lowering `num_speculative_tokens` from 5 to 3.** Positions 4 and 5 are
  accepted only 29% and 21% of the time, so fewer drafts would waste less
  verification work but also lose some accepted tokens. It may be a wash; it has
  not been measured.
- **The KV cache does not need periodic cleaning.** vLLM allocates and frees KV
  blocks itself, and the prefix cache evicts on demand when space is needed. A
  restart is not a maintenance step.

## Related

- dotfiles `spark-vllm/RUNBOOK.md`: start/restart, QSFP, the full outage record
  ("Outage 2026-11-15"), and earlier incidents
- `docs/gpu-models.md`: what runs where and how to swap models
- `scripts/spark-vllm-bench/README.md`: how the benchmarks measure
