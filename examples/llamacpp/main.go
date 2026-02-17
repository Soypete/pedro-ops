package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"

	"github.com/davecgh/go-spew/spew"
	"github.com/soypete/pedro-ops/metrics"
)

type ChatRequest struct {
	Messages []Message `json:"messages"`
	Stream   bool      `json:"stream"`
}

type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

func main() {

	// llama.cpp server endpoint (default local server)
	endpoint := "http://localhost:8080/v1/chat/completions"

	// Create a simple chat request
	request := ChatRequest{
		Messages: []Message{
			{
				Role:       "system",
				Content: "you are a chatbot. please interact with the user.",
			},
			{
				Role:    "user",
				Content: "Hello, how are you?",
			},
		},
		Stream: false,
	}

	// Marshal request to JSON
	jsonData, err := json.Marshal(request)
	if err != nil {
		log.Fatalf("Error marshaling request: %v", err)
	}

	// Create HTTP request
	req, err := http.NewRequest("POST", endpoint, bytes.NewBuffer(jsonData))
	if err != nil {
		log.Fatalf("Error creating request: %v", err)
	}

	// Set headers
	req.Header.Set("Content-Type", "application/json")

	// Make the request
	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		log.Fatalf("Error making request: %v", err)
	}
	defer resp.Body.Close()

	// Read response
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		log.Fatalf("Error reading response: %v", err)
	} // Check if request was successful
	if resp.StatusCode != http.StatusOK {
		log.Fatalf("Request failed with status %d: %s", resp.StatusCode, string(body))
	}

	// Parse response
	metricsCalculator := metrics.SetupCalulator()
	responseMetrics, derrivedMetrics, err := metricsCalculator.CalculateMetrics(body)
	if err != nil {
		log.Fatalf("Error calculating metrics: %v", err)
	}

	spew.Dump(responseMetrics)
	fmt.Println(derrivedMetrics)
}
