package main

import (
	"log"
	"net/http"
	"os"
)

func envOrDefault(key, fallback string) string {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}

	return value
}

func listenAddr() string {
	if addr := os.Getenv("E2E_ECHO_LISTEN_ADDR"); addr != "" {
		return addr
	}

	port := envOrDefault("NOMAD_PORT_http", "8080")
	return ":" + port
}

func main() {
	addr := listenAddr()
	responseText := envOrDefault("E2E_ECHO_TEXT", "Hello from e2e echo")

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte(responseText))
	})

	server := &http.Server{
		Addr:    addr,
		Handler: handler,
	}

	log.Printf("starting e2e echo server on %s", addr)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("start e2e echo server: %v", err)
	}
}
