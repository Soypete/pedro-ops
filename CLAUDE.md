# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Pedro Ops is a Go-based AI observability service that provides metrics collection and monitoring for OpenAI API interactions. It acts as a middleware proxy to capture performance metrics and export them to Prometheus/OTEL-compatible systems.

## Development Commands

```bash
# Initialize Go module (when ready)
go mod init github.com/Soypete/pedro-ops

# Build the application
go build -o pedro-ops

# Run tests
go test ./...

# Run with race detection
go test -race ./...

# Format code
go fmt ./...

# Lint code (requires golangci-lint)
golangci-lint run

# Run the application
./pedro-ops
```

## Architecture Overview

- **Proxy Service**: HTTP middleware that intercepts OpenAI API requests/responses
- **Metrics Collector**: Captures timing and performance data from API interactions
- **Exporter**: Sends metrics to Prometheus or OTEL-compatible backends
- **Configuration**: Environment-based configuration for API keys and endpoints

## Key Metrics to Implement

- Time-to-First-Token (TTFT)
- Average prompt processing time
- Token generation rates
- API latency measurements
- Request/response payload sizes

## Integration Target

Initial integration with [pedroGPT](https://github.com/Soypete/iam_pedro) for AI observability.

## Go Project Conventions

- Use standard Go project layout
- Follow effective Go naming conventions
- Implement proper error handling with wrapped errors
- Use context for request lifecycle management
- Apply dependency injection for testability