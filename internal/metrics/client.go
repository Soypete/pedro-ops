package metrics

import (
	"expvar"
	"fmt"
	"sync"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/soypete/pedro-ops/internal/types"
)

// Client handles both Prometheus and expvar metrics
type Client struct {
	// Prometheus metrics
	apiLatency       *prometheus.HistogramVec
	timeToFirstToken *prometheus.HistogramVec
	promptProcessing *prometheus.HistogramVec
	tokenGeneration  *prometheus.HistogramVec
	tokensPerSecond  *prometheus.GaugeVec
	requestCounter   *prometheus.CounterVec
	tokenCounter     *prometheus.CounterVec
	requestSize      *prometheus.HistogramVec
	responseSize     *prometheus.HistogramVec

	// Expvar metrics
	expvarMutex   sync.RWMutex
	requestCounts map[string]*expvar.Int
	errorCounts   map[string]*expvar.Int
	avgLatency    map[string]*expvar.Float
	avgTTFT       map[string]*expvar.Float
}

// NewClient creates a new metrics client with both Prometheus and expvar support
func NewClient() *Client {
	client := &Client{
		requestCounts: make(map[string]*expvar.Int),
		errorCounts:   make(map[string]*expvar.Int),
		avgLatency:    make(map[string]*expvar.Float),
		avgTTFT:       make(map[string]*expvar.Float),
	}

	client.initPrometheusMetrics()
	client.initExpvarMetrics()

	return client
}

func (c *Client) initPrometheusMetrics() {
	// API Latency histogram
	c.apiLatency = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "openai_api_latency_milliseconds",
			Help:    "API latency in milliseconds",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"model", "endpoint"},
	)

	// Time to First Token histogram
	c.timeToFirstToken = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "openai_time_to_first_token_milliseconds",
			Help:    "Time to first token in milliseconds",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"model", "endpoint"},
	)

	// Prompt processing time histogram
	c.promptProcessing = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "openai_prompt_processing_milliseconds",
			Help:    "Prompt processing time in milliseconds",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"model", "endpoint"},
	)

	// Token generation time histogram
	c.tokenGeneration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "openai_token_generation_milliseconds",
			Help:    "Token generation time in milliseconds",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"model", "endpoint"},
	)

	// Tokens per second gauge
	c.tokensPerSecond = promauto.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "openai_tokens_per_second",
			Help: "Tokens generated per second",
		},
		[]string{"model", "endpoint"},
	)

	// Request counter
	c.requestCounter = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "openai_requests_total",
			Help: "Total number of OpenAI API requests",
		},
		[]string{"model", "endpoint", "status"},
	)

	// Token counter
	c.tokenCounter = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "openai_tokens_total",
			Help: "Total number of tokens processed",
		},
		[]string{"model", "endpoint", "type"},
	)

	// Request size histogram
	c.requestSize = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "openai_request_size_bytes",
			Help:    "Request size in bytes",
			Buckets: prometheus.ExponentialBuckets(100, 2, 10),
		},
		[]string{"model", "endpoint"},
	)

	// Response size histogram
	c.responseSize = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "openai_response_size_bytes",
			Help:    "Response size in bytes",
			Buckets: prometheus.ExponentialBuckets(100, 2, 10),
		},
		[]string{"model", "endpoint"},
	)
}

func (c *Client) initExpvarMetrics() {
	// Initialize base expvar metrics
	expvar.NewString("service").Set("pedro-ops")
	expvar.NewString("version").Set("1.0.0")
}

// RecordMetrics records metrics from a response
func (c *Client) RecordMetrics(metrics *types.ResponseMetrics) {
	labels := []string{metrics.Model, metrics.Endpoint}
	status := fmt.Sprintf("%d", metrics.StatusCode)

	calculated := metrics.CalculateMetrics()

	// Record Prometheus metrics
	if latency, ok := calculated["api_latency_ms"]; ok {
		c.apiLatency.WithLabelValues(labels...).Observe(latency)
	}

	if ttft, ok := calculated["time_to_first_token_ms"]; ok {
		c.timeToFirstToken.WithLabelValues(labels...).Observe(ttft)
	}

	if procTime, ok := calculated["prompt_processing_time_ms"]; ok {
		c.promptProcessing.WithLabelValues(labels...).Observe(procTime)
	}

	if genTime, ok := calculated["token_generation_time_ms"]; ok {
		c.tokenGeneration.WithLabelValues(labels...).Observe(genTime)
	}

	if tps, ok := calculated["tokens_per_second"]; ok {
		c.tokensPerSecond.WithLabelValues(labels...).Set(tps)
	}

	// Request counter
	c.requestCounter.WithLabelValues(metrics.Model, metrics.Endpoint, status).Inc()

	// Token counters
	if metrics.PromptTokens > 0 {
		c.tokenCounter.WithLabelValues(metrics.Model, metrics.Endpoint, "prompt").Add(float64(metrics.PromptTokens))
	}
	if metrics.CompletionTokens > 0 {
		c.tokenCounter.WithLabelValues(metrics.Model, metrics.Endpoint, "completion").Add(float64(metrics.CompletionTokens))
	}

	// Size metrics
	if reqSize, ok := calculated["request_size_bytes"]; ok {
		c.requestSize.WithLabelValues(labels...).Observe(reqSize)
	}
	if respSize, ok := calculated["response_size_bytes"]; ok {
		c.responseSize.WithLabelValues(labels...).Observe(respSize)
	}

	// Record expvar metrics
	c.recordExpvarMetrics(metrics, calculated)
}

func (c *Client) recordExpvarMetrics(metrics *types.ResponseMetrics, calculated map[string]float64) {
	c.expvarMutex.Lock()
	defer c.expvarMutex.Unlock()

	key := fmt.Sprintf("%s_%s", metrics.Model, metrics.Endpoint)

	// Request counts
	if _, exists := c.requestCounts[key]; !exists {
		c.requestCounts[key] = expvar.NewInt(fmt.Sprintf("requests_%s", key))
	}
	c.requestCounts[key].Add(1)

	// Error counts
	if metrics.StatusCode >= 400 {
		if _, exists := c.errorCounts[key]; !exists {
			c.errorCounts[key] = expvar.NewInt(fmt.Sprintf("errors_%s", key))
		}
		c.errorCounts[key].Add(1)
	}

	// Average latency
	if latency, ok := calculated["api_latency_ms"]; ok {
		if _, exists := c.avgLatency[key]; !exists {
			c.avgLatency[key] = expvar.NewFloat(fmt.Sprintf("avg_latency_%s", key))
		}
		c.avgLatency[key].Set(latency)
	}

	// Average TTFT
	if ttft, ok := calculated["time_to_first_token_ms"]; ok {
		if _, exists := c.avgTTFT[key]; !exists {
			c.avgTTFT[key] = expvar.NewFloat(fmt.Sprintf("avg_ttft_%s", key))
		}
		c.avgTTFT[key].Set(ttft)
	}
}
