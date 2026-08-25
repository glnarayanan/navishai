package events

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

func TestSinkAuthenticatesCanonicalEventDelivery(t *testing.T) {
	secret := []byte("runner-event-secret-that-is-at-least-32-bytes")
	now := time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)
	workspaceKey := "c9bb966b-1fe9-4304-bd51-404e4fd9a09c"
	event, err := protocol.NewCanonicalEvent(
		"3d07f334-88ef-4fe4-a640-421e3ba79921", 2, "run.started", now,
		map[string]any{"adapter": "scripted", "scenario": "success", "attempt": 1},
	)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		body, _ := io.ReadAll(request.Body)
		timestamp := request.Header.Get("X-NavishAI-Timestamp")
		if request.URL.Path != eventPath || request.Header.Get("X-NavishAI-Workspace-Key") != workspaceKey ||
			!protocol.Verify(secret, timestamp, request.Method, request.URL.Path, body, request.Header.Get("X-NavishAI-Signature")) {
			t.Error("event request was not bound to its path, workspace, and body")
			response.WriteHeader(http.StatusUnauthorized)
			return
		}
		var delivered protocol.CanonicalEvent
		if err := json.Unmarshal(body, &delivered); err != nil || delivered.EventID != event.EventID {
			t.Errorf("unexpected event body: %#v err=%v", delivered, err)
		}
		response.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()

	sink, err := New(server.URL, secret, false, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	if err := sink.Deliver(context.Background(), workspaceKey, event); err != nil {
		t.Fatal(err)
	}
}

func TestSinkRejectsUnsafeConfigurationAndMapsConflict(t *testing.T) {
	secret := []byte("runner-event-secret-that-is-at-least-32-bytes")
	if _, err := New("http://control-plane.internal", secret, false, time.Now); err != ErrConfiguration {
		t.Fatalf("expected cleartext non-loopback rejection, got %v", err)
	}
	if _, err := New("http://control-plane.internal", secret, true, time.Now); err != nil {
		t.Fatalf("expected explicit private HTTP opt-in, got %v", err)
	}
	if _, err := New("https://user@example.com", secret, false, time.Now); err != ErrConfiguration {
		t.Fatalf("expected credential-bearing URL rejection, got %v", err)
	}

	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		response.WriteHeader(http.StatusConflict)
	}))
	defer server.Close()
	sink, err := New(server.URL, secret, false, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	event, _ := protocol.NewCanonicalEvent(
		"3d07f334-88ef-4fe4-a640-421e3ba79921", 2, "run.started", time.Now(),
		map[string]any{"adapter": "scripted", "scenario": "success", "attempt": 1},
	)
	if err := sink.Deliver(context.Background(), "c9bb966b-1fe9-4304-bd51-404e4fd9a09c", event); err != ErrConflict {
		t.Fatalf("expected conflict, got %v", err)
	}
}
