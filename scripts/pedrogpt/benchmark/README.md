# pedrogpt llama.cpp benchmark

Measures live throughput of the llama-server on pedrogpt by streaming
`/v1/chat/completions` and reading llama.cpp's ground-truth `timings` (prompt t/s,
generated t/s, and MTP draft-acceptance when present), plus client-side TTFT and
p50/p95 latency. Use it to capture a before/after table when changing the build,
model, or flags.

## CLI

```bash
cd scripts/pedrogpt/benchmark
go run . -url http://pedrogpt:8080/v1 -model qwen3.6-27b-mtp -n 10
go run . -prompt "Write a Go HTTP server with graceful shutdown." -max-tokens 512
```

Flags: `-url`, `-model`, `-n`, `-max-tokens`, `-prompt`, `-warmup`.

## go test -bench

Skips unless `PEDROGPT_URL` is set, so `go test ./...` stays hermetic:

```bash
PEDROGPT_URL=http://pedrogpt:8080/v1 PEDROGPT_MODEL=qwen3.6-27b-mtp \
  go test -bench=ChatCompletion -benchtime=10x ./scripts/pedrogpt/benchmark/
```

## Raw server-side bench (no API)

For pure model throughput independent of the HTTP server, use `llama-bench` on the box
(this is the methodology recorded in `~/code/pedro/benchmarks.md`):

```bash
/opt/llama.cpp/build/bin/llama-bench \
  -m /opt/models/qwen3.6-27b-mtp/<file>.gguf \
  -fa 1 -d 0,4096,8192,16384,32768 -p 2048 -n 32 -ub 1024 -ngl 99
```

> Note: `llama-bench` measures the model/kernels, not MTP — MTP is a server-side
> speculative-decoding feature, so the API benchmark above is what shows the MTP gain.
