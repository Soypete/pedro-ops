// package types defines the data structures for OpenAI API responses and metrics.
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
	PromptTokens            int                     `json:"prompt_tokens"`
	CompletionTokens        int                     `json:"completion_tokens,omitempty"`
	TotalTokens             int                     `json:"total_tokens"`
	PromptTokensDetails     PromptTokensDetails     `json:"prompt_tokens_details"`
	CompletionTokensDetails CompletionTokensDetails `json:"completion_tokens_details"`
	ServiceTier             string                  `json:"service_tier"`
}

// PromptTokensDetails contains details about prompt tokens
type PromptTokensDetails struct {
	CachedTokens int `json:"cached_tokens"`
	AudioTokens  int `json:"audio_tokens"`
}

// CompletionTokensDetails contains details about completion tokens
type CompletionTokensDetails struct {
	ReasoningTokens          int `json:"reasoning_tokens"`
	AudioTokens              int `json:"audio_tokens"`
	AcceptedPredictionTokens int `json:"accepted_prediction_tokens"`
	RejectedPredictionTokens int `json:"rejected_prediction_tokens"`
}

// ResponseMetrics contains timing and performance metrics for API calls
type ResponseMetrics struct {
	//RequestStartTime is the time that the handler  that calls llm is called.
	RequestStartTime time.Time
	// ResponseStartTime is the time that the llm is called.
	ResponseStartTime time.Time
	// FirstTokenTime time that llm response is recieved.
	FirstTokenTime time.Time
	// ResponseEndTime after handler completes
	ResponseEndTime  time.Time
	Model            string
	PromptTokens     int
	CompletionTokens int
	TotalTokens      int
	ResponseSize     int64
	Endpoint         string
	StatusCode       int
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
	metrics["response_size_bytes"] = float64(rm.ResponseSize)

	return metrics
}
