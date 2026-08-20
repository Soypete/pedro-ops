// Command compare measures time-to-first-token across two OpenAI-compatible
// inference backends and prints a side-by-side table.
//
// # WHY THIS EXISTS
//
// The obvious approach — scrape each server's own Prometheus metrics — does not give
// a fair comparison here:
//
//   - vLLM exposes a true TTFT histogram, but its prefill-derived throughput is
//     inflated: request_prefill_time_seconds is wall-clock per request while vLLM
//     prefills many requests concurrently in a batch, so summing it undercounts
//     compute time.
//   - llama.cpp exposes NO TTFT metric at all — only cumulative counters. Any TTFT
//     figure for it must be modelled from prefill throughput.
//
// Measuring client-side sidesteps both problems: identical prompts, identical
// measurement, one stopwatch. What the user actually experiences in opencode is the
// wall-clock delay until the first token appears, which is exactly what this measures.
//
// CAVEATS, so the numbers are not oversold:
//
//   - This measures the FULL client-observed latency: network (Tailscale), queueing,
//     scheduling, and prefill. That is the honest user-facing number, but it means a
//     slower result is not necessarily slower prefill.
//   - Backends under concurrent load from other users will look worse. Run when idle,
//     or state the load conditions.
//   - Reasoning models emit reasoning_content before content. This tool counts the
//     first token of EITHER as the first token, since that is when output starts
//     streaming. Comparing a reasoning model against a non-reasoning one is not
//     apples-to-apples regardless of how TTFT is measured.
//   - pedrogpt runs a router with --models-max 1. If the requested model is not
//     resident, the first request pays a ~18 GB load. Use -warmup (default) so that
//     cost is excluded, and be aware the warmup request itself may take minutes.
//
// USAGE
//
//	go run ./compare \
//	  -a http://pedrogpt:8000/v1,qwen3.8-27b \
//	  -b http://100.87.122.109:8000/v1,QuantTrio/MiniMax-M2.5-AWQ \
//	  -n 10
//
// Any number of backends may be given by repeating -a/-b/-c... or using -backend.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"
)

type backend struct {
	label string
	url   string
	model string
}

// backendList collects repeated -backend flags.
type backendList []backend

func (b *backendList) String() string { return fmt.Sprint(*b) }

func (b *backendList) Set(v string) error {
	// form: URL,MODEL[,LABEL]
	parts := strings.Split(v, ",")
	if len(parts) < 2 {
		return fmt.Errorf("want URL,MODEL[,LABEL], got %q", v)
	}
	be := backend{url: strings.TrimSpace(parts[0]), model: strings.TrimSpace(parts[1])}
	if len(parts) > 2 {
		be.label = strings.TrimSpace(parts[2])
	} else {
		be.label = be.model
	}
	*b = append(*b, be)
	return nil
}

type message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type chatRequest struct {
	Model     string    `json:"model"`
	Messages  []message `json:"messages"`
	Stream    bool      `json:"stream"`
	MaxTokens int       `json:"max_tokens"`
	// Deterministic sampling so repeated runs are comparable.
	Temperature float64 `json:"temperature"`
	// Both servers omit the usage block from a stream unless asked, which would
	// leave the generated-token count (and so tok/s) at zero.
	StreamOptions streamOptions `json:"stream_options"`
}

type streamOptions struct {
	IncludeUsage bool `json:"include_usage"`
}

// streamChunk covers the fields both llama.cpp and vLLM emit.
//
// Thinking models stream their reasoning before the answer, and the two servers spell
// that field DIFFERENTLY: llama.cpp uses "reasoning_content", vLLM uses "reasoning".
// Both are decoded here — missing one makes every chunk look empty and the whole
// backend appear to return nothing at all.
type streamChunk struct {
	Choices []struct {
		Delta struct {
			Content          string `json:"content"`
			ReasoningContent string `json:"reasoning_content"`
			Reasoning        string `json:"reasoning"`
		} `json:"delta"`
	} `json:"choices"`
	Usage *struct {
		CompletionTokens int `json:"completion_tokens"`
		PromptTokens     int `json:"prompt_tokens"`
	} `json:"usage"`
}

type runResult struct {
	ttftMS        float64
	totalMS       float64
	genTokens     int
	genPerSec     float64
	reasonedFirst bool
	err           error
}

func main() {
	var backends backendList
	flag.Var(&backends, "backend", "backend as URL,MODEL[,LABEL] (repeatable)")
	a := flag.String("a", "", "shorthand for -backend (first backend)")
	b := flag.String("b", "", "shorthand for -backend (second backend)")
	n := flag.Int("n", 10, "measured requests per backend")
	maxTokens := flag.Int("max-tokens", 64, "max tokens to generate (kept small: TTFT is the target, not throughput)")
	prompt := flag.String("prompt", "In one sentence, what is a write-ahead log?", "prompt sent to every backend")
	warmup := flag.Bool("warmup", true, "send one discarded request first (model load / cache warm)")
	timeout := flag.Duration("timeout", 10*time.Minute, "per-request timeout (generous: a cold router load moves ~18 GB)")
	interleave := flag.Bool("interleave", true, "rotate backends per round so drift in load affects both equally")
	flag.Parse()

	for _, s := range []string{*a, *b} {
		if s != "" {
			if err := backends.Set(s); err != nil {
				fmt.Fprintln(os.Stderr, "error:", err)
				os.Exit(2)
			}
		}
	}
	if len(backends) < 2 {
		fmt.Fprintln(os.Stderr, "need at least two backends; see -h")
		flag.Usage()
		os.Exit(2)
	}

	client := &http.Client{Timeout: *timeout}

	fmt.Printf("prompt     : %q\n", *prompt)
	fmt.Printf("max_tokens : %d   requests: %d   interleave: %v\n\n", *maxTokens, *n, *interleave)

	if *warmup {
		fmt.Println("warming up (discarded; a cold router load can take minutes)...")
		for _, be := range backends {
			r := runOnce(client, be, *prompt, *maxTokens)
			status := fmt.Sprintf("%.0f ms", r.ttftMS)
			if r.err != nil {
				status = "FAILED: " + r.err.Error()
			}
			fmt.Printf("  %-28s %s\n", be.label, status)
		}
		fmt.Println()
	}

	results := make(map[string][]runResult, len(backends))

	if *interleave {
		// Round-robin: any drift in cluster load hits all backends alike.
		for i := 0; i < *n; i++ {
			for _, be := range backends {
				r := runOnce(client, be, *prompt, *maxTokens)
				results[be.label] = append(results[be.label], r)
				report1(i+1, be, r)
			}
		}
	} else {
		for _, be := range backends {
			for i := 0; i < *n; i++ {
				r := runOnce(client, be, *prompt, *maxTokens)
				results[be.label] = append(results[be.label], r)
				report1(i+1, be, r)
			}
		}
	}

	fmt.Println()
	summarize(backends, results)
}

func report1(i int, be backend, r runResult) {
	if r.err != nil {
		fmt.Printf("  %2d %-28s ERROR %v\n", i, be.label, r.err)
		return
	}
	note := ""
	if r.reasonedFirst {
		note = "  (reasoning first)"
	}
	fmt.Printf("  %2d %-28s ttft %7.1f ms | total %8.1f ms | %3d tok | %5.1f tok/s%s\n",
		i, be.label, r.ttftMS, r.totalMS, r.genTokens, r.genPerSec, note)
}

func runOnce(client *http.Client, be backend, prompt string, maxTokens int) runResult {
	body, err := json.Marshal(chatRequest{
		Model:         be.model,
		Messages:      []message{{Role: "user", Content: prompt}},
		Stream:        true,
		MaxTokens:     maxTokens,
		Temperature:   0,
		StreamOptions: streamOptions{IncludeUsage: true},
	})
	if err != nil {
		return runResult{err: err}
	}

	endpoint := strings.TrimSuffix(be.url, "/") + "/chat/completions"
	req, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return runResult{err: err}
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "text/event-stream")

	start := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return runResult{err: err}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return runResult{err: fmt.Errorf("status %d: %s", resp.StatusCode, strings.TrimSpace(string(msg)))}
	}

	var res runResult
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
			continue // keepalives / partial lines
		}
		if firstToken.IsZero() && len(chunk.Choices) > 0 {
			d := chunk.Choices[0].Delta
			// Count reasoning too: on a thinking model that is when output actually
			// starts streaming, and ignoring it would overstate TTFT.
			reasoning := d.ReasoningContent + d.Reasoning
			if d.Content != "" || reasoning != "" {
				firstToken = time.Now()
				res.reasonedFirst = d.Content == "" && reasoning != ""
			}
		}
		if chunk.Usage != nil && chunk.Usage.CompletionTokens > 0 {
			res.genTokens = chunk.Usage.CompletionTokens
		}
	}
	if err := scanner.Err(); err != nil {
		return runResult{err: err}
	}

	res.totalMS = float64(time.Since(start).Microseconds()) / 1000
	if firstToken.IsZero() {
		return runResult{err: fmt.Errorf("no content received")}
	}
	res.ttftMS = float64(firstToken.Sub(start).Microseconds()) / 1000
	if gen := res.totalMS - res.ttftMS; gen > 0 && res.genTokens > 0 {
		res.genPerSec = float64(res.genTokens) / (gen / 1000)
	}
	return res
}

func summarize(backends []backend, results map[string][]runResult) {
	fmt.Println("=== TTFT (client-measured: network + queue + prefill) ===")
	fmt.Printf("%-30s %8s %9s %9s %9s %8s\n", "backend", "n", "p50 ms", "p95 ms", "mean ms", "tok/s")
	fmt.Println(strings.Repeat("-", 78))

	type row struct {
		label string
		p50   float64
	}
	var rows []row

	for _, be := range backends {
		rs := results[be.label]
		var ttft, gen []float64
		fails := 0
		for _, r := range rs {
			if r.err != nil {
				fails++
				continue
			}
			ttft = append(ttft, r.ttftMS)
			if r.genPerSec > 0 {
				gen = append(gen, r.genPerSec)
			}
		}
		if len(ttft) == 0 {
			fmt.Printf("%-30s %8s %9s %9s %9s %8s\n", trunc(be.label, 30), "0", "-", "-", "-", "-")
			continue
		}
		tokStr := "-"
		if len(gen) > 0 {
			tokStr = fmt.Sprintf("%.1f", mean(gen))
		}
		fmt.Printf("%-30s %8d %9.1f %9.1f %9.1f %8s\n",
			trunc(be.label, 30), len(ttft),
			percentile(ttft, 50), percentile(ttft, 95), mean(ttft), tokStr)
		if fails > 0 {
			fmt.Printf("%-30s   (%d request(s) failed)\n", "", fails)
		}
		rows = append(rows, row{be.label, percentile(ttft, 50)})
	}

	if len(rows) >= 2 {
		sort.Slice(rows, func(i, j int) bool { return rows[i].p50 < rows[j].p50 })
		best, worst := rows[0], rows[len(rows)-1]
		if best.p50 > 0 {
			fmt.Printf("\n%s is %.2fx faster to first token than %s (p50).\n",
				best.label, worst.p50/best.p50, worst.label)
		}
	}

	fmt.Println("\nNote: TTFT here is the full client-observed delay — network, queueing and")
	fmt.Println("prefill — which is what a user feels, but it is not prefill time alone.")
	fmt.Println("Backends serving other traffic during the run will look worse.")
}

func trunc(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}

func mean(v []float64) float64 {
	if len(v) == 0 {
		return 0
	}
	var s float64
	for _, x := range v {
		s += x
	}
	return s / float64(len(v))
}

func percentile(v []float64, p float64) float64 {
	if len(v) == 0 {
		return 0
	}
	s := append([]float64(nil), v...)
	sort.Float64s(s)
	if len(s) == 1 {
		return s[0]
	}
	idx := (p / 100) * float64(len(s)-1)
	lo := int(math.Floor(idx))
	hi := int(math.Ceil(idx))
	if lo == hi {
		return s[lo]
	}
	frac := idx - float64(lo)
	return s[lo]*(1-frac) + s[hi]*frac
}
