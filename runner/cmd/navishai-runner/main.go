package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	address := os.Getenv("NAVISHAI_RUNNER_ADDRESS")
	if address == "" {
		address = ":8081"
	}

	server := &http.Server{
		Addr:              address,
		Handler:           newHandler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	log.Printf("NavishAI runner listening on %s", address)
	log.Fatal(server.ListenAndServe())
}

func newHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /livez", healthHandler)
	mux.HandleFunc("GET /readyz", healthHandler)
	return mux
}

func healthHandler(response http.ResponseWriter, _ *http.Request) {
	response.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(response).Encode(map[string]string{"status": "ok"})
}
