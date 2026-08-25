package runtimecatalog

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

func TestHandlerAuthenticatesDetectionRequests(t *testing.T) {
	secret := []byte("runtime-handler-secret-at-least-32-bytes")
	now := time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)
	handler, err := NewHandler(secret, Empty(), func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]string{"protocol_version": protocol.Version, "workspace_key": "c9bb966b-1fe9-4304-bd51-404e4fd9a09c"})
	request := httptest.NewRequest(http.MethodPost, DetectionPath, bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	timestamp := strconv.FormatInt(now.Unix(), 10)
	request.Header.Set("X-NavishAI-Timestamp", timestamp)
	signature, err := protocol.Sign(secret, request.Header.Get("X-NavishAI-Timestamp"), http.MethodPost, DetectionPath, body)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("X-NavishAI-Signature", signature)
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK || response.Body.String() != "{\"installations\":[],\"protocol_version\":\"v1\"}\n" {
		t.Fatalf("unexpected response %d %s", response.Code, response.Body.String())
	}
	unauthorized := httptest.NewRequest(http.MethodPost, DetectionPath, bytes.NewReader(body))
	unauthorized.Header.Set("Content-Type", "application/json")
	unauthorizedResponse := httptest.NewRecorder()
	handler.ServeHTTP(unauthorizedResponse, unauthorized)
	if unauthorizedResponse.Code != http.StatusUnauthorized {
		t.Fatalf("expected unauthorized, got %d", unauthorizedResponse.Code)
	}
}
