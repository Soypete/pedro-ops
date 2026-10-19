package main

import (
	"math"
	"strings"
	"testing"
	"time"
)

// fakeClock returns start+step on the first call, start+2*step on the second, and so on.
func fakeClock(start time.Time, step time.Duration) func() time.Time {
	n := 0
	return func() time.Time {
		n++
		return start.Add(time.Duration(n) * step)
	}
}

func sse(lines ...string) string {
	return "data: " + strings.Join(lines, "\n\ndata: ") + "\n\n"
}

const timingsChunk = `{"choices":[],"timings":{"prompt_per_second":50,"predicted_per_second":25,"predicted_n":40,"draft_n":10,"draft_n_accepted":8}}`

func TestReadStreamTTFTCountsReasoningTokens(t *testing.T) {
	start := time.Unix(0, 0)
	stream := sse(
		`{"choices":[{"delta":{"reasoning_content":"Let me think"}}]}`,
		`{"choices":[{"delta":{"content":"Hello"}}]}`,
		timingsChunk,
		"[DONE]",
	)
	res, err := readStream(strings.NewReader(stream), start, fakeClock(start, 100*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	if res.ttftMS != 100 {
		t.Errorf("ttft = %v ms, want 100 (first reasoning token counts)", res.ttftMS)
	}
	if res.totalMS != 200 {
		t.Errorf("total = %v ms, want 200", res.totalMS)
	}
}

func TestReadStreamTTFTWithPlainContent(t *testing.T) {
	start := time.Unix(0, 0)
	stream := sse(`{"choices":[{"delta":{"content":"Hi"}}]}`, "[DONE]")
	res, err := readStream(strings.NewReader(stream), start, fakeClock(start, 50*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	if res.ttftMS != 50 {
		t.Errorf("ttft = %v ms, want 50", res.ttftMS)
	}
}

func TestReadStreamReportsTimingsAndMTPAcceptance(t *testing.T) {
	start := time.Unix(0, 0)
	res, err := readStream(strings.NewReader(sse(`{"choices":[{"delta":{"content":"x"}}]}`, timingsChunk, "[DONE]")),
		start, fakeClock(start, time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	if res.genPerSecond != 25 || res.promptPerSec != 50 || res.predictedN != 40 {
		t.Errorf("timings not parsed: %+v", res)
	}
	if math.Abs(res.acceptRate-0.8) > 1e-9 {
		t.Errorf("acceptRate = %v, want 0.8", res.acceptRate)
	}
}

func TestReadStreamAcceptRateIsMinusOneWhenTheServerDoesNotReportDrafts(t *testing.T) {
	start := time.Unix(0, 0)
	chunk := `{"choices":[],"timings":{"prompt_per_second":50,"predicted_per_second":25,"predicted_n":40}}`
	res, err := readStream(strings.NewReader(sse(`{"choices":[{"delta":{"content":"x"}}]}`, chunk, "[DONE]")),
		start, fakeClock(start, time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	if res.acceptRate != -1 {
		t.Errorf("acceptRate = %v, want -1", res.acceptRate)
	}
}

func TestReadStreamWithNoTokensLeavesTTFTAtZero(t *testing.T) {
	start := time.Unix(0, 0)
	res, err := readStream(strings.NewReader(sse(`{"choices":[{"delta":{}}]}`, "[DONE]")), start, fakeClock(start, time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	if res.ttftMS != 0 {
		t.Errorf("ttft = %v, want 0 when no token arrived", res.ttftMS)
	}
}
