package types

import "time"

// ChatCompletionResponse represents the response from OpenAI chat completions API
type ChatCompletionResponse struct {
	ID      string                 `json:"id"`
	Object  string                 `json:"object"`
	Created int64                  `json:"created"`
	Model   string                 `json:"model"`
	Choices []ChatCompletionChoice `json:"choices"`
	Usage   Usage                  `json:"usage"`
}

// ChatCompletionChoice represents a single choice in the completion response
type ChatCompletionChoice struct {
	Index        int                    `json:"index"`
	Message      ChatCompletionMessage  `json:"message"`
	FinishReason string                 `json:"finish_reason"`
	Delta        *ChatCompletionMessage `json:"delta,omitempty"`
}

// ChatCompletionMessage represents a message in the chat completion
type ChatCompletionMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// EmbeddingResponse represents the response from OpenAI embeddings API
type EmbeddingResponse struct {
	Object string      `json:"object"`
	Data   []Embedding `json:"data"`
	Model  string      `json:"model"`
	Usage  Usage       `json:"usage"`
}

// Embedding represents a single embedding result
type Embedding struct {
	Object    string    `json:"object"`
	Index     int       `json:"index"`
	Embedding []float64 `json:"embedding"`
}

// Usage represents token usage information in API responses
type Usage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens,omitempty"`
	TotalTokens      int `json:"total_tokens"`
}

// ResponseMetrics contains timing and performance metrics for API calls
type ResponseMetrics struct {
	RequestStartTime  time.Time
	ResponseStartTime time.Time
	FirstTokenTime    time.Time
	ResponseEndTime   time.Time
	Model             string
	PromptTokens      int
	CompletionTokens  int
	TotalTokens       int
	RequestSize       int64
	ResponseSize      int64
	Endpoint          string
	StatusCode        int
}

// CalculateMetrics computes derived metrics from the response data
func (rm *ResponseMetrics) CalculateMetrics() map[string]float64 {
	metrics := make(map[string]float64)

	// API Latency (total time)
	if !rm.ResponseEndTime.IsZero() && !rm.RequestStartTime.IsZero() {
		metrics["api_latency_ms"] = float64(rm.ResponseEndTime.Sub(rm.RequestStartTime).Nanoseconds()) / 1e6
	}

	// Time to First Token (TTFT)
	if !rm.FirstTokenTime.IsZero() && !rm.RequestStartTime.IsZero() {
		metrics["time_to_first_token_ms"] = float64(rm.FirstTokenTime.Sub(rm.RequestStartTime).Nanoseconds()) / 1e6
	}

	// Prompt Processing Time
	if !rm.ResponseStartTime.IsZero() && !rm.RequestStartTime.IsZero() {
		metrics["prompt_processing_time_ms"] = float64(rm.ResponseStartTime.Sub(rm.RequestStartTime).Nanoseconds()) / 1e6
	}

	// Token Generation Time
	if !rm.ResponseEndTime.IsZero() && !rm.FirstTokenTime.IsZero() && rm.CompletionTokens > 0 {
		totalGenTime := rm.ResponseEndTime.Sub(rm.FirstTokenTime)
		metrics["token_generation_time_ms"] = float64(totalGenTime.Nanoseconds()) / 1e6
		metrics["tokens_per_second"] = float64(rm.CompletionTokens) / totalGenTime.Seconds()
	}

	// Token counts
	metrics["prompt_tokens"] = float64(rm.PromptTokens)
	metrics["completion_tokens"] = float64(rm.CompletionTokens)
	metrics["total_tokens"] = float64(rm.TotalTokens)

	// Request/Response sizes
	metrics["request_size_bytes"] = float64(rm.RequestSize)
	metrics["response_size_bytes"] = float64(rm.ResponseSize)

	return metrics
}
