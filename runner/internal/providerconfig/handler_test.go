package providerconfig

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

type fixedStatus struct{}

func (fixedStatus) ProviderAvailability(*http.Request, string, string) Availability {
	return Availability{HealthStatus: "available", Available: true, ExecutableVersion: "1.2.3"}
}

func TestHandlerAuthenticatesStrictSchemasAndNeverReturnsSecrets(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	store, _ := OpenStore("", testSecret)
	handler, err := NewHandler(testSecret, store, fixedStatus{}, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	apiKey := "sk-handler-secret-value"
	configured := serve(t, handler, ConfigurePath, map[string]any{
		"protocol_version": protocol.Version, "workspace_key": workspaceOne,
		"request_id": workspaceTwo, "adapter_key": CodexAdapterKey,
		"auth_mode": "api_key", "model": "gpt-5", "api_key": apiKey,
	}, now, testSecret)
	if configured.Code != http.StatusOK || strings.Contains(configured.Body.String(), apiKey) {
		t.Fatalf("configure response status=%d body=%s", configured.Code, configured.Body.String())
	}
	var configuredPayload struct {
		ProtocolVersion string   `json:"protocol_version"`
		WorkspaceKey    string   `json:"workspace_key"`
		Provider        Provider `json:"provider"`
	}
	if json.Unmarshal(configured.Body.Bytes(), &configuredPayload) != nil || !configuredPayload.Provider.Configured ||
		!configuredPayload.Provider.SecretConfigured || configuredPayload.Provider.AuthMode != "api_key" {
		t.Fatalf("unexpected configure response: %#v", configuredPayload)
	}
	var exact map[string]any
	if json.Unmarshal(configured.Body.Bytes(), &exact) != nil || len(exact) != 3 {
		t.Fatalf("configure response has unexpected top-level fields: %s", configured.Body.String())
	}
	providerObject, ok := exact["provider"].(map[string]any)
	if !ok || len(providerObject) != 12 {
		t.Fatalf("configure response has unexpected provider fields: %#v", exact["provider"])
	}
	replay := serve(t, handler, ConfigurePath, map[string]any{
		"protocol_version": protocol.Version, "workspace_key": workspaceOne,
		"request_id": workspaceTwo, "adapter_key": CodexAdapterKey,
		"auth_mode": "api_key", "model": "gpt-5", "api_key": apiKey,
	}, now, testSecret)
	if replay.Code != http.StatusOK || replay.Header().Get("X-NavishAI-Idempotent-Replay") != "true" {
		t.Fatalf("same request was not replayed safely: status=%d headers=%v", replay.Code, replay.Header())
	}
	conflict := serve(t, handler, ConfigurePath, map[string]any{
		"protocol_version": protocol.Version, "workspace_key": workspaceOne,
		"request_id": workspaceTwo, "adapter_key": CodexAdapterKey,
		"auth_mode": "api_key", "model": "gpt-changed", "api_key": apiKey,
	}, now, testSecret)
	if conflict.Code != http.StatusConflict || strings.Contains(conflict.Body.String(), apiKey) {
		t.Fatalf("request-id conflict status=%d body=%s", conflict.Code, conflict.Body.String())
	}
	catalog := serve(t, handler, CatalogPath, map[string]any{
		"protocol_version": protocol.Version, "workspace_key": workspaceOne,
	}, now, testSecret)
	if catalog.Code != http.StatusOK || strings.Contains(catalog.Body.String(), apiKey) {
		t.Fatalf("catalog response status=%d body=%s", catalog.Code, catalog.Body.String())
	}
	var catalogPayload struct {
		Providers []Provider `json:"providers"`
	}
	if json.Unmarshal(catalog.Body.Bytes(), &catalogPayload) != nil || len(catalogPayload.Providers) != 4 {
		t.Fatalf("unexpected catalog: %s", catalog.Body.String())
	}
	badSignature := serve(t, handler, CatalogPath, map[string]any{
		"protocol_version": protocol.Version, "workspace_key": workspaceOne,
	}, now, []byte("wrong-provider-secret-that-is-at-least-32-bytes"))
	if badSignature.Code != http.StatusUnauthorized {
		t.Fatalf("bad signature status = %d", badSignature.Code)
	}
	unknown := serve(t, handler, ConfigurePath, map[string]any{
		"protocol_version": protocol.Version, "workspace_key": workspaceOne, "request_id": workspaceTwo,
		"adapter_key": CodexAdapterKey, "auth_mode": "subscription", "model": "", "api_key": "", "extra": true,
	}, now, testSecret)
	if unknown.Code != http.StatusUnprocessableEntity {
		t.Fatalf("unknown field status = %d", unknown.Code)
	}
}

func TestHandlerPurgesOneWorkspaceThroughSignedProtocol(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	store, _ := OpenStore("", testSecret)
	if _, err := store.Configure(workspaceOne, CodexAdapterKey, "api_key", "gpt-5", "sk-purge-target-value"); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Configure(workspaceTwo, CodexAdapterKey, "api_key", "gpt-5", "sk-purge-other-value"); err != nil {
		t.Fatal(err)
	}
	handler, err := NewHandler(testSecret, store, fixedStatus{}, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	response := serve(t, handler, PurgePath, map[string]any{
		"protocol_version": protocol.Version,
		"workspace_key":    workspaceOne,
		"request_id":       "74efec9a-dfdd-474f-8644-f34d2720cf1d",
	}, now, testSecret)
	if response.Code != http.StatusOK {
		t.Fatalf("purge status=%d body=%s", response.Code, response.Body.String())
	}
	var payload map[string]any
	if json.Unmarshal(response.Body.Bytes(), &payload) != nil || len(payload) != 3 || payload["purged"] != true || payload["workspace_key"] != workspaceOne {
		t.Fatalf("unexpected purge response: %s", response.Body.String())
	}
	if _, configured := store.Get(workspaceOne, CodexAdapterKey); configured {
		t.Fatal("signed purge retained target workspace credentials")
	}
	if _, configured := store.Get(workspaceTwo, CodexAdapterKey); !configured {
		t.Fatal("signed purge removed another workspace credentials")
	}
	unsigned := httptest.NewRequest(http.MethodPost, PurgePath, strings.NewReader(`{"protocol_version":"v1"}`))
	unsigned.Header.Set("Content-Type", "application/json")
	unsignedResponse := httptest.NewRecorder()
	handler.ServeHTTP(unsignedResponse, unsigned)
	if unsignedResponse.Code != http.StatusUnauthorized {
		t.Fatalf("unsigned purge status=%d body=%s", unsignedResponse.Code, unsignedResponse.Body.String())
	}
}

func serve(t *testing.T, handler http.Handler, path string, input map[string]any, now time.Time, secret []byte) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	timestamp := strconv.FormatInt(now.Unix(), 10)
	signature, err := protocol.Sign(secret, timestamp, request.Method, path, body)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("X-NavishAI-Timestamp", timestamp)
	request.Header.Set("X-NavishAI-Signature", signature)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}
