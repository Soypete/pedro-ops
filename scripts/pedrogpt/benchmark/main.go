// Command benchmark measures llama.cpp server throughput on pedrogpt.
//
// It hits the OpenAI-compatible /v1/chat/completions endpoint N times and reports
// the server's own ground-truth timings (prompt tokens/sec and generated tokens/sec
// from llama.cpp's `timings` object), client-side time-to-first-token (measured from
// the stream), and p50/p95 latency. Use it to capture a before/after table when
// changing the build, model, or flags (e.g. enabling MTP).
//
// Usage:
//
//	go run . -url http://pedrogpt:8000/v1 -model qwen3.6-27b-mtp -n 10
//	go run . -prompt "Write a Go HTTP server with graceful shutdown." -max-tokens 512
//
// The server must be started with timings enabled (default for llama-server). This
// tool requests streaming so it can measure TTFT and reads the final `timings` object.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"
)

type chatRequest struct {
	Model     string    `json:"model"`
	Messages  []message `json:"messages"`
	Stream    bool      `json:"stream"`
	MaxTokens int       `json:"max_tokens"`
	// Ask llama.cpp to include its timing block in the streamed response.
	StreamOptions streamOptions `json:"stream_options"`
	Timings       bool          `json:"timings_per_token,omitempty"`
}

type streamOptions struct {
	IncludeUsage bool `json:"include_usage"`
}

type message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// timings mirrors llama.cpp's server `timings` object (the ground-truth numbers).
type timings struct {
	PromptN            int     `json:"prompt_n"`
	PromptMS           float64 `json:"prompt_ms"`
	PromptPerSecond    float64 `json:"prompt_per_second"`
	PredictedN         int     `json:"predicted_n"`
	PredictedMS        float64 `json:"predicted_ms"`
	PredictedPerSecond float64 `json:"predicted_per_second"`
	// MTP / speculative acceptance, when present.
	DraftN         int `json:"draft_n,omitempty"`
	DraftNAccepted int `json:"draft_n_accepted,omitempty"`
}

// streamChunk is a single SSE data line from llama-server.
type streamChunk struct {
	Choices []struct {
		Delta struct {
			Content string `json:"content"`
		} `json:"delta"`
	} `json:"choices"`
	Timings *timings `json:"timings"`
}

type runResult struct {
	ttftMS       float64
	totalMS      float64
	genPerSecond float64
	promptPerSec float64
	predictedN   int
	acceptRate   float64 // MTP draft acceptance, -1 if not reported
}

func main() {
	var (
		url       = flag.String("url", "http://pedrogpt:8000/v1", "llama-server base URL")
		model     = flag.String("model", "qwen3.6-27b-mtp", "model id (must match the server alias)")
		n         = flag.Int("n", 5, "number of requests")
		maxTokens = flag.Int("max-tokens", 256, "max tokens to generate per request")
		prompt    = flag.String("prompt", "Explain how multi-token prediction speeds up LLM inference, in three sentences.", "user prompt")
		warmup    = flag.Bool("warmup", true, "discard the first request (model load / cache warm)")
	)
	flag.Parse()

	endpoint := strings.TrimRight(*url, "/") + "/chat/completions"
	fmt.Printf("Benchmarking %s\n  model=%s n=%d max-tokens=%d\n\n", endpoint, *model, *n, *maxTokens)

	total := *n
	if *warmup {
		total++
	}

	var results []runResult
	for i := 0; i < total; i++ {
		r, err := runOnce(endpoint, *model, *prompt, *maxTokens)
		if err != nil {
			fmt.Fprintf(os.Stderr, "request %d failed: %v\n", i, err)
			os.Exit(1)
		}
		if *warmup && i == 0 {
			fmt.Printf("warmup: gen %.1f tok/s (discarded)\n\n", r.genPerSecond)
			continue
		}
		results = append(results, r)
		fmt.Printf("run %2d: ttft %6.1f ms | total %7.1f ms | prompt %7.1f t/s | gen %6.1f t/s",
			len(results), r.ttftMS, r.totalMS, r.promptPerSec, r.genPerSecond)
		if r.acceptRate >= 0 {
			fmt.Printf(" | mtp accept %4.1f%%", r.acceptRate*100)
		}
		fmt.Println()
	}

	report(results)
}

func runOnce(endpoint, model, prompt string, maxTokens int) (runResult, error) {
	reqBody := chatRequest{
		Model:         model,
		Messages:      []message{{Role: "user", Content: prompt}},
		Stream:        true,
		MaxTokens:     maxTokens,
		StreamOptions: streamOptions{IncludeUsage: true},
		Timings:       true,
	}
	buf, err := json.Marshal(reqBody)
	if err != nil {
		return runResult{}, err
	}

	start := time.Now()
	req, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(buf))
	if err != nil {
		return runResult{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "text/event-stream")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return runResult{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := readAll(resp.Body)
		return runResult{}, fmt.Errorf("status %d: %s", resp.StatusCode, b)
	}

	res := runResult{acceptRate: -1}
	var firstToken time.Time
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		data := strings.TrimPrefix(line, "data: ")
		if data == "[DONE]" {
			break
		}
		var chunk streamChunk
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			continue // tolerate keepalives / partial lines
		}
		if firstToken.IsZero() && len(chunk.Choices) > 0 && chunk.Choices[0].Delta.Content != "" {
			firstToken = time.Now()
		}
		if chunk.Timings != nil {
			res.promptPerSec = chunk.Timings.PromptPerSecond
			res.genPerSecond = chunk.Timings.PredictedPerSecond
			res.predictedN = chunk.Timings.PredictedN
			if chunk.Timings.DraftN > 0 {
				res.acceptRate = float64(chunk.Timings.DraftNAccepted) / float64(chunk.Timings.DraftN)
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return runResult{}, err
	}

	res.totalMS = float64(time.Since(start).Microseconds()) / 1000
	if !firstToken.IsZero() {
		res.ttftMS = float64(firstToken.Sub(start).Microseconds()) / 1000
	}
	return res, nil
}

func report(results []runResult) {
	if len(results) == 0 {
		return
	}
	gen := field(results, func(r runResult) float64 { return r.genPerSecond })
	prompt := field(results, func(r runResult) float64 { return r.promptPerSec })
	ttft := field(results, func(r runResult) float64 { return r.ttftMS })
	total := field(results, func(r runResult) float64 { return r.totalMS })

	fmt.Printf("\n=== Summary (n=%d) ===\n", len(results))
	fmt.Printf("  Generation   : %.1f t/s median (min %.1f, max %.1f)\n", median(gen), gen[0], gen[len(gen)-1])
	fmt.Printf("  Prompt eval  : %.1f t/s median\n", median(prompt))
	fmt.Printf("  TTFT         : p50 %.1f ms | p95 %.1f ms\n", percentile(ttft, 50), percentile(ttft, 95))
	fmt.Printf("  Total latency: p50 %.1f ms | p95 %.1f ms\n", percentile(total, 50), percentile(total, 95))
	if results[0].acceptRate >= 0 {
		acc := field(results, func(r runResult) float64 { return r.acceptRate })
		fmt.Printf("  MTP accept   : %.1f%% median\n", median(acc)*100)
	}
}

func field(rs []runResult, f func(runResult) float64) []float64 {
	out := make([]float64, len(rs))
	for i, r := range rs {
		out[i] = f(r)
	}
	sort.Float64s(out)
	return out
}

func median(sorted []float64) float64 { return percentile(sorted, 50) }

// percentile returns the p-th percentile of an already-sorted slice (nearest-rank).
func percentile(sorted []float64, p int) float64 {
	if len(sorted) == 0 {
		return 0
	}
	rank := (p * len(sorted)) / 100
	if rank >= len(sorted) {
		rank = len(sorted) - 1
	}
	return sorted[rank]
}

func readAll(r interface{ Read([]byte) (int, error) }) (string, error) {
	var sb strings.Builder
	b := make([]byte, 4096)
	for {
		n, err := r.Read(b)
		sb.Write(b[:n])
		if err != nil {
			if err.Error() == "EOF" {
				return sb.String(), nil
			}
			return sb.String(), nil
		}
	}
}
