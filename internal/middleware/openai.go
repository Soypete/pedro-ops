package middleware

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/soypete/pedro-ops/internal/metrics"
	"github.com/soypete/pedro-ops/types"
)

const (
	openaiBaseURL       = "https://api.openai.com"
	completionsEndpoint = "/v1/chat/completions"
	embeddingsEndpoint  = "/v1/embeddings"
)

// OpenAIMiddleware handles OpenAI API requests and extracts metrics
type OpenAIMiddleware struct {
	metricsClient *metrics.Client
	apiKey        string
	httpClient    *http.Client
}

// NewOpenAIMiddleware creates a new OpenAI middleware instance
func NewOpenAIMiddleware() *OpenAIMiddleware {
	apiKey := os.Getenv("OPENAI_API_KEY")
	if apiKey == "" {
		// log.Printf("Warning: OPENAI_API_KEY not set")
		apiKey = "test"
	}

	return &OpenAIMiddleware{
		apiKey: apiKey,
		httpClient: &http.Client{
			Timeout: 60 * time.Second,
		},
	}
}

// ExtractMetrics extracts metrics from the response body and updates the response metrics struct for the given endpoint.
func (m *OpenAIMiddleware) ExtractMetrics(responseBody []byte, metrics *types.ResponseMetrics, endpoint string) {
	switch endpoint {
	case "completions":
		m.extractCompletionMetrics(responseBody, metrics)
	case "embeddings":
		m.extractEmbeddingMetrics(responseBody, metrics)
	}
}

func (m *OpenAIMiddleware) extractCompletionMetrics(responseBody []byte, metrics *types.ResponseMetrics) {
	var response types.ChatCompletionResponse
	if err := json.Unmarshal(responseBody, &response); err != nil {
		log.Printf("Error parsing completion response: %v", err)
		return
	}

	metrics.Model = response.Model
	metrics.PromptTokens = response.Usage.PromptTokens
	metrics.CompletionTokens = response.Usage.CompletionTokens
	metrics.TotalTokens = response.Usage.TotalTokens

	// For streaming responses, we would need to detect first token differently
	// For now, we'll use response start time as first token time for non-streaming
	if len(response.Choices) > 0 && response.Choices[0].Message.Content != "" {
		metrics.FirstTokenTime = metrics.ResponseStartTime
	}
}

func (m *OpenAIMiddleware) extractEmbeddingMetrics(responseBody []byte, metrics *types.ResponseMetrics) {
	var response types.EmbeddingResponse
	if err := json.Unmarshal(responseBody, &response); err != nil {
		log.Printf("Error parsing embedding response: %v", err)
		return
	}

	metrics.Model = response.Model
	metrics.PromptTokens = response.Usage.PromptTokens
	metrics.TotalTokens = response.Usage.TotalTokens
	// Embeddings don't have completion tokens
	metrics.CompletionTokens = 0

	// For embeddings, first token time is essentially response start time
	metrics.FirstTokenTime = metrics.ResponseStartTime
}

// Helper function to detect if response is streaming based on content-type or other headers
func isStreamingResponse(headers http.Header) bool {
	contentType := headers.Get("Content-Type")
	return strings.Contains(contentType, "text/event-stream") ||
		strings.Contains(contentType, "application/x-ndjson")
}
