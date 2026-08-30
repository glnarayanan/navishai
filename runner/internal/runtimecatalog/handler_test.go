package runtimecatalog

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

func TestHandlerPreservesLegacyV1AndServesConfigurationIdentityInV2(t *testing.T) {
	secret := []byte("runtime-handler-secret-at-least-32-bytes")
	now := time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)
	catalog, err := NewWithInstallations(nil, []Installation{{
		DetectionKey: strings.Repeat("a", 64), AdapterKey: "scripted", ProtocolVersion: protocol.Version,
		ExecutablePath: "/opt/navishai/fixture", ExecutableVersion: "fixture 1.0.0",
		AccountMetadata: map[string]string{"authentication": "built_in"}, Capabilities: []string{"structured_output"},
		EffectiveModel: "deterministic_fixture", ConfigurationFingerprint: strings.Repeat("b", 64),
		MinimumVersion: "1.0.0", MaximumVersion: "1.0.0", CompatibilityStatus: "compatible",
		HealthStatus: "available", CheckedAt: now.Format(time.RFC3339),
	}}, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	v2Handler, err := NewHandler(secret, catalog, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	legacyHandler, err := NewLegacyHandler(secret, catalog, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}

	v2 := performDetection(t, v2Handler, secret, now, DetectionPath, DetectionVersion)
	v2Installation := v2["installations"].([]any)[0].(map[string]any)
	if v2["protocol_version"] != DetectionVersion || v2Installation["effective_model"] != "deterministic_fixture" ||
		v2Installation["configuration_fingerprint"] != strings.Repeat("b", 64) {
		t.Fatalf("v2 response omitted configuration identity: %#v", v2)
	}

	legacy := performDetection(t, legacyHandler, secret, now, LegacyDetectionPath, protocol.Version)
	legacyInstallation := legacy["installations"].([]any)[0].(map[string]any)
	if legacy["protocol_version"] != protocol.Version {
		t.Fatalf("unexpected legacy protocol: %#v", legacy)
	}
	if _, exists := legacyInstallation["effective_model"]; exists {
		t.Fatalf("legacy response exposed effective_model: %#v", legacyInstallation)
	}
	if _, exists := legacyInstallation["configuration_fingerprint"]; exists {
		t.Fatalf("legacy response exposed configuration_fingerprint: %#v", legacyInstallation)
	}

	body, _ := json.Marshal(map[string]string{"protocol_version": DetectionVersion, "workspace_key": "c9bb966b-1fe9-4304-bd51-404e4fd9a09c"})
	unauthorized := httptest.NewRequest(http.MethodPost, DetectionPath, bytes.NewReader(body))
	unauthorized.Header.Set("Content-Type", "application/json")
	unauthorizedResponse := httptest.NewRecorder()
	v2Handler.ServeHTTP(unauthorizedResponse, unauthorized)
	if unauthorizedResponse.Code != http.StatusUnauthorized {
		t.Fatalf("expected unauthorized, got %d", unauthorizedResponse.Code)
	}
}

func performDetection(t *testing.T, handler http.Handler, secret []byte, now time.Time, path, version string) map[string]any {
	t.Helper()
	body, _ := json.Marshal(map[string]string{
		"protocol_version": version, "workspace_key": "c9bb966b-1fe9-4304-bd51-404e4fd9a09c",
	})
	request := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	timestamp := strconv.FormatInt(now.Unix(), 10)
	request.Header.Set("X-NavishAI-Timestamp", timestamp)
	signature, err := protocol.Sign(secret, timestamp, http.MethodPost, path, body)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("X-NavishAI-Signature", signature)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("unexpected response %d %s", response.Code, response.Body.String())
	}
	var payload map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	return payload
}
