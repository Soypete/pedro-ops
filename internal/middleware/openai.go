package middleware

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/soypete/pedro-ops/types"
)

// OpenAIMiddleware handles OpenAI API requests and extracts metrics
type OpenAIMiddleware struct {
	apiKey     string
	httpClient *http.Client
}

// NewOpenAIMiddleware creates a new OpenAI middleware instance
func NewOpenAIMiddleware() *OpenAIMiddleware {
	apiKey := os.Getenv("OPENAI_API_KEY")
	if apiKey == "" {
		apiKey = "test"
	}

	return &OpenAIMiddleware{
		apiKey: apiKey,
		httpClient: &http.Client{
			Timeout: 60 * time.Second,
		},
	}
}

// ExtractMetrics extracts metrics from the response body and updates
// the response metrics struct for the given endpoint.
func (m *OpenAIMiddleware) ExtractMetrics(
	responseBody []byte,
	metrics *types.ResponseMetrics,
	endpoint string,
) {
	switch endpoint {
	case "completions":
		m.extractCompletionMetrics(responseBody, metrics)
	case "embeddings":
		m.extractEmbeddingMetrics(responseBody, metrics)
	}
}

func (m *OpenAIMiddleware) extractCompletionMetrics(
	responseBody []byte,
	metrics *types.ResponseMetrics,
) {
	var response types.ChatCompletionResponse
	if err := json.Unmarshal(responseBody, &response); err != nil {
		log.Printf("Error parsing completion response: %v", err)
		return
	}

	metrics.Model = response.Model
	metrics.PromptTokens = response.Usage.PromptTokens
	metrics.CompletionTokens = response.Usage.CompletionTokens
	metrics.TotalTokens = response.Usage.TotalTokens

	if len(response.Choices) > 0 && response.Choices[0].Message.Content != "" {
		metrics.FirstTokenTime = metrics.ResponseStartTime
	}
}

func (m *OpenAIMiddleware) extractEmbeddingMetrics(
	responseBody []byte,
	metrics *types.ResponseMetrics,
) {
	var response types.EmbeddingResponse
	if err := json.Unmarshal(responseBody, &response); err != nil {
		log.Printf("Error parsing embedding response: %v", err)
		return
	}

	metrics.Model = response.Model
	metrics.PromptTokens = response.Usage.PromptTokens
	metrics.TotalTokens = response.Usage.TotalTokens
	metrics.CompletionTokens = 0
	metrics.FirstTokenTime = metrics.ResponseStartTime
}
