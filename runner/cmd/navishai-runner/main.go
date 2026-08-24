package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/admission"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
)

func main() {
	address := os.Getenv("NAVISHAI_RUNNER_BIND_ADDRESS")
	if address == "" {
		address = "127.0.0.1:8081"
	}
	secret := []byte(os.Getenv("NAVISHAI_RUNNER_SHARED_SECRET"))
	statePath := os.Getenv("NAVISHAI_RUNNER_STATE_PATH")
	if statePath == "" {
		statePath = "tmp/runner-admissions.json"
	}
	store, err := admission.OpenStore(statePath)
	if err != nil {
		log.Fatalf("open runner admission state: %v", err)
	}
	handler, err := newHandler(secret, store, time.Now)
	if err != nil {
		log.Fatalf("configure runner protocol: %v", err)
	}

	server := &http.Server{
		Addr:              address,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	log.Printf("NavishAI runner listening on %s", address)
	log.Fatal(server.ListenAndServe())
}

func newHandler(secret []byte, store *admission.Store, now func() time.Time) (http.Handler, error) {
	admissionHandler, err := admission.NewHandler(secret, store, now)
	if err != nil {
		return nil, fmt.Errorf("create admission handler: %w", err)
	}
	runtimeHandler, err := runtimecatalog.NewHandler(secret, runtimecatalog.Empty(), now)
	if err != nil {
		return nil, fmt.Errorf("create runtime detection handler: %w", err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /livez", healthHandler)
	mux.HandleFunc("GET /readyz", healthHandler)
	mux.Handle("POST /v1/runs/admit", admissionHandler)
	mux.Handle("POST "+runtimecatalog.DetectionPath, runtimeHandler)
	return mux, nil
}

func healthHandler(response http.ResponseWriter, _ *http.Request) {
	response.Header().Set("Content-Type", "application/json")
	response.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(response).Encode(map[string]any{
		"status": "ok", "protocol_versions": []string{protocol.Version},
	})
}
