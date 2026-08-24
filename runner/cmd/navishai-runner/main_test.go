package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/admission"
)

func TestHealthEndpoints(t *testing.T) {
	store, err := admission.OpenStore("")
	if err != nil {
		t.Fatal(err)
	}
	handler, err := newHandler([]byte("runner-test-secret-that-is-at-least-32-bytes"), store, "", time.Now)
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/livez", "/readyz"} {
		t.Run(path, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, path, nil)
			response := httptest.NewRecorder()

			handler.ServeHTTP(response, request)

			if response.Code != http.StatusOK {
				t.Fatalf("expected status %d, got %d", http.StatusOK, response.Code)
			}
			if contentType := response.Header().Get("Content-Type"); contentType != "application/json" {
				t.Fatalf("expected application/json, got %q", contentType)
			}
			if body := response.Body.String(); body != "{\"protocol_versions\":[\"v1\"],\"status\":\"ok\"}\n" {
				t.Fatalf("unexpected response body %q", body)
			}
		})
	}
}

func TestHandlerRequiresASecret(t *testing.T) {
	store, err := admission.OpenStore("")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := newHandler([]byte("short"), store, "", time.Now); err == nil {
		t.Fatal("expected a short secret to fail")
	}
}

func TestTLSFiles(t *testing.T) {
	tests := []struct {
		name        string
		environment map[string]string
		certificate string
		key         string
		wantError   bool
	}{
		{name: "cleartext loopback default", environment: map[string]string{}},
		{name: "certificate pair", environment: map[string]string{
			"NAVISHAI_RUNNER_TLS_CERT_FILE": "/run/secrets/runner.crt",
			"NAVISHAI_RUNNER_TLS_KEY_FILE":  "/run/secrets/runner.key",
		}, certificate: "/run/secrets/runner.crt", key: "/run/secrets/runner.key"},
		{name: "missing key", environment: map[string]string{
			"NAVISHAI_RUNNER_TLS_CERT_FILE": "/run/secrets/runner.crt",
		}, wantError: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			certificate, key, err := tlsFiles(func(name string) string { return test.environment[name] })
			if (err != nil) != test.wantError {
				t.Fatalf("unexpected error: %v", err)
			}
			if certificate != test.certificate || key != test.key {
				t.Fatalf("got certificate %q and key %q", certificate, key)
			}
		})
	}
}
