package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthEndpoints(t *testing.T) {
	for _, path := range []string{"/livez", "/readyz"} {
		t.Run(path, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, path, nil)
			response := httptest.NewRecorder()

			newHandler().ServeHTTP(response, request)

			if response.Code != http.StatusOK {
				t.Fatalf("expected status %d, got %d", http.StatusOK, response.Code)
			}
			if contentType := response.Header().Get("Content-Type"); contentType != "application/json" {
				t.Fatalf("expected application/json, got %q", contentType)
			}
			if body := response.Body.String(); body != "{\"status\":\"ok\"}\n" {
				t.Fatalf("unexpected response body %q", body)
			}
		})
	}
}
