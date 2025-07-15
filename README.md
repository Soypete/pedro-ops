# Pedro Ops

Pedro Ops is a lightweight AI observability service built in Go that provides comprehensive monitoring and metrics for AI applications. It intercepts and analyzes OpenAI API requests to deliver real-time performance insights and operational metrics.

## Features

- **Real-time Metrics Collection**: Capture detailed performance metrics from OpenAI API interactions
- **Time-to-First-Token (TTFT)**: Measure latency from request to first token generation
- **Prompt Processing Analytics**: Track average prompt processing times and throughput
- **Token Generation Metrics**: Monitor token generation rates and completion times
- **API Latency Monitoring**: Comprehensive request/response timing analysis
- **OTEL Compliance**: Export metrics to Prometheus and other OpenTelemetry-compatible systems
- **Lightweight Architecture**: Minimal resource footprint with high-performance Go runtime

## Architecture

Pedro Ops operates as a middleware service that sits between your AI applications and the OpenAI API, providing transparent observability without modifying your existing code.

```
[AI Application] → [Pedro Ops] → [OpenAI API]
                       ↓
              [Prometheus/OTEL Collector]
```

## Getting Started

### Prerequisites

- Go 1.21 or higher
- Access to OpenAI API
- Prometheus or OTEL-compatible metrics backend

### Installation

```bash
git clone https://github.com/Soypete/pedro-ops.git
cd pedro-ops
go mod tidy
go build -o pedro-ops
```

### Configuration

Configure Pedro Ops using environment variables or a configuration file:

```bash
export OPENAI_API_KEY="your-api-key"
export PROMETHEUS_ENDPOINT="http://localhost:9090"
export PEDRO_OPS_PORT="8080"
```

## Integration

Pedro Ops will initially integrate with [pedroGPT](https://github.com/Soypete/iam_pedro) to provide observability for AI-powered applications.

### Framework Compatibility

**Note**: Consider integration strategies for popular AI frameworks:
- **LangChain (Python)**: How to configure base URLs to route through Pedro Ops proxy
- **OpenAI SDK**: Direct integration patterns for both Python and JavaScript/TypeScript clients
- **LangChain-Go**: Integration approaches for Go-based LangChain implementations
- **Custom HTTP clients**: Documentation for configuring any HTTP client to use Pedro Ops as proxy

Future development should include examples and configuration guides for each of these frameworks to ensure seamless adoption.

## Development Roadmap

### Phase 1: Core Infrastructure
- [ ] Set up Go project structure with proper modules
- [ ] Implement OpenAI API request/response interceptor
- [ ] Create basic HTTP server for proxy functionality
- [ ] Add configuration management (environment variables, config files)

### Phase 2: Metrics Collection
- [ ] Implement time-to-first-token measurement
- [ ] Add prompt processing time tracking
- [ ] Create token generation rate calculations
- [ ] Build API latency monitoring
- [ ] Add request/response size tracking

### Phase 3: Export & Integration
- [ ] Implement Prometheus metrics exporter
- [ ] Add OpenTelemetry compatibility
- [ ] Create health check endpoints
- [ ] Build graceful shutdown handling

### Phase 4: Advanced Features
- [ ] Add request filtering and sampling
- [ ] Implement custom metric definitions
- [ ] Create dashboard configuration templates
- [ ] Add alerting rule suggestions

### Phase 5: Production Readiness
- [ ] Add comprehensive logging
- [ ] Implement rate limiting protection
- [ ] Create Docker containerization
- [ ] Add Kubernetes deployment manifests
- [ ] Write comprehensive documentation

### Phase 6: Testing & Quality
- [ ] Write unit tests for core functionality
- [ ] Add integration tests with OpenAI API
- [ ] Create performance benchmarks
- [ ] Set up CI/CD pipeline

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.