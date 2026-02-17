package main

import (
	_ "net/http/pprof"
)

func main() {
	// log.Println("Starting Pedro Ops - AI Observability Service")

	// // Initialize metrics client
	// metricsClient := metrics.NewClient()

	// // Initialize OpenAI middleware
	// openaiMiddleware := middleware.NewOpenAIMiddleware(metricsClient)

	// // Setup metrics server
	// mux := http.NewServeMux()

	// // Prometheus metrics endpoint
	// mux.Handle("/metrics", promhttp.Handler())

	// // Expvar endpoint for runtime metrics
	// mux.Handle("/debug/vars", expvar.Handler())

	// // Health check endpoint
	// mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
	// 	w.WriteHeader(http.StatusOK)
	// 	fmt.Fprintf(w, "OK")
	// })

	// // OpenAI proxy endpoints
	// mux.HandleFunc("/v1/chat/completions", openaiMiddleware.HandleCompletions)
	// mux.HandleFunc("/v1/embeddings", openaiMiddleware.HandleEmbeddings)

	// server := &http.Server{
	// 	Addr:         ":6060",
	// 	Handler:      mux,
	// 	ReadTimeout:  30 * time.Second,
	// 	WriteTimeout: 30 * time.Second,
	// 	IdleTimeout:  60 * time.Second,
	// }

	// // Graceful shutdown handling
	// ctx, cancel := context.WithCancel(context.Background())
	// defer cancel()

	// // Start server in goroutine
	// go func() {
	// 	log.Printf("Metrics server starting on %s", server.Addr)
	// 	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
	// 		log.Fatalf("Server failed to start: %v", err)
	// 	}
	// }()

	// // Wait for interrupt signal
	// sigChan := make(chan os.Signal, 1)
	// signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	// <-sigChan

	// log.Println("Shutting down server...")

	// // Graceful shutdown with timeout
	// shutdownCtx, shutdownCancel := context.WithTimeout(ctx, 30*time.Second)
	// defer shutdownCancel()

	// if err := server.Shutdown(shutdownCtx); err != nil {
	// 	log.Printf("Server shutdown error: %v", err)
	// }

	// log.Println("Server shutdown complete")
}
