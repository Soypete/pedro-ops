package middleware

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/soypete/pedro-ops/internal/metrics"
	"github.com/soypete/pedro-ops/internal/types"
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
func NewOpenAIMiddleware(metricsClient *metrics.Client) *OpenAIMiddleware {
	apiKey := os.Getenv("OPENAI_API_KEY")
	if apiKey == "" {
		log.Printf("Warning: OPENAI_API_KEY not set")
	}

	return &OpenAIMiddleware{
		metricsClient: metricsClient,
		apiKey:        apiKey,
		httpClient: &http.Client{
			Timeout: 60 * time.Second,
		},
	}
}

// HandleCompletions processes chat completion requests
func (m *OpenAIMiddleware) HandleCompletions(w http.ResponseWriter, r *http.Request) {
	m.handleRequest(w, r, completionsEndpoint, "completions")
}

// HandleEmbeddings processes embedding requests
func (m *OpenAIMiddleware) HandleEmbeddings(w http.ResponseWriter, r *http.Request) {
	m.handleRequest(w, r, embeddingsEndpoint, "embeddings")
}

func (m *OpenAIMiddleware) handleRequest(w http.ResponseWriter, r *http.Request, endpoint, endpointName string) {
	responseMetrics := &types.ResponseMetrics{
		RequestStartTime: time.Now(),
		Endpoint:         endpointName,
	}

	// Read the request body
	requestBody, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Failed to read request body", http.StatusBadRequest)
		return
	}
	r.Body.Close()

	responseMetrics.RequestSize = int64(len(requestBody))

	// Create request to OpenAI
	openaiURL := openaiBaseURL + endpoint
	req, err := http.NewRequest(r.Method, openaiURL, bytes.NewReader(requestBody))
	if err != nil {
		http.Error(w, "Failed to create request", http.StatusInternalServerError)
		return
	}

	// Copy headers
	for key, values := range r.Header {
		for _, value := range values {
			req.Header.Add(key, value)
		}
	}

	// Set OpenAI API key if not already present
	if m.apiKey != "" && req.Header.Get("Authorization") == "" {
		req.Header.Set("Authorization", "Bearer "+m.apiKey)
	}

	responseMetrics.ResponseStartTime = time.Now()

	// Make the request to OpenAI
	resp, err := m.httpClient.Do(req)
	if err != nil {
		log.Printf("Error calling OpenAI API: %v", err)
		http.Error(w, "Failed to call OpenAI API", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	responseMetrics.StatusCode = resp.StatusCode

	// Read the response body
	responseBody, err := io.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, "Failed to read response", http.StatusInternalServerError)
		return
	}

	responseMetrics.ResponseSize = int64(len(responseBody))
	responseMetrics.ResponseEndTime = time.Now()

	// Extract metrics from response
	m.extractMetrics(responseBody, responseMetrics, endpointName)

	// Copy response headers
	for key, values := range resp.Header {
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}

	// Set response status and write body
	w.WriteHeader(resp.StatusCode)
	if _, err := w.Write(responseBody); err != nil {
		log.Printf("Error writing response: %v", err)
	}

	// Record metrics
	m.metricsClient.RecordMetrics(responseMetrics)
}

func (m *OpenAIMiddleware) extractMetrics(responseBody []byte, metrics *types.ResponseMetrics, endpoint string) {
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
