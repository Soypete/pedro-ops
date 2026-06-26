package main

import (
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

// BenchmarkChatCompletion drives the live llama-server and reports generated tok/s
// as a custom metric. It is skipped unless PEDROGPT_URL is set, so `go test ./...`
// stays hermetic in CI.
//
//	PEDROGPT_URL=http://pedrogpt:8080/v1 PEDROGPT_MODEL=qwen3.6-27b-mtp \
//	  go test -bench=ChatCompletion -benchtime=10x ./scripts/pedrogpt/benchmark/
func BenchmarkChatCompletion(b *testing.B) {
	base := os.Getenv("PEDROGPT_URL")
	if base == "" {
		b.Skip("set PEDROGPT_URL to run the live benchmark (e.g. http://pedrogpt:8080/v1)")
	}
	model := os.Getenv("PEDROGPT_MODEL")
	if model == "" {
		model = "qwen3.6-27b-mtp"
	}
	endpoint := strings.TrimRight(base, "/") + "/chat/completions"
	const prompt = "Explain how multi-token prediction speeds up LLM inference, in three sentences."

	if !serverUp(base) {
		b.Skipf("server at %s not reachable", base)
	}

	// Warm the model once (load / cache) before timing.
	if _, err := runOnce(endpoint, model, prompt, 64); err != nil {
		b.Fatalf("warmup failed: %v", err)
	}

	var genSum, promptSum float64
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r, err := runOnce(endpoint, model, prompt, 256)
		if err != nil {
			b.Fatalf("request failed: %v", err)
		}
		genSum += r.genPerSecond
		promptSum += r.promptPerSec
	}
	b.StopTimer()

	if b.N > 0 {
		b.ReportMetric(genSum/float64(b.N), "gen_tok/s")
		b.ReportMetric(promptSum/float64(b.N), "prompt_tok/s")
	}
}

func serverUp(base string) bool {
	health := strings.TrimRight(strings.TrimSuffix(base, "/v1"), "/") + "/health"
	client := http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get(health)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}
