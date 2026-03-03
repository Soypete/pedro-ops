# Llama.cpp Client Example

This is a simple Go client that demonstrates making a single chat completion request to a llama.cpp server.

## Prerequisites

- Go 1.21 or later
- A running llama.cpp server (default: http://localhost:8080)

## Usage

1. Start your llama.cpp server:
   ```bash
   # Example llama.cpp server command
   ./server -m your-model.gguf --port 8080
   ```

2. Run the example:
   ```bash
   cd examples/llamacpp
   go run main.go
   ```

## Configuration

The client connects to `http://localhost:8080/v1/chat/completions` by default. Modify the `endpoint` variable in `main.go` to connect to a different server.

## Example Output

```
Response: Hello! I'm doing well, thank you for asking. How can I help you today?
```