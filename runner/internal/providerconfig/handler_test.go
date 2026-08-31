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

type recordingModelDiscovery struct {
	results    map[string]ModelDiscovery
	workspaces []string
	adapters   []string
}

func (source *recordingModelDiscovery) DiscoverModels(_ *http.Request, workspaceKey, adapterKey string) ModelDiscovery {
	source.workspaces = append(source.workspaces, workspaceKey)
	source.adapters = append(source.adapters, adapterKey)
	if result, ok := source.results[workspaceKey]; ok {
		return result
	}
	return ModelDiscovery{Status: ModelDiscoveryFailed}
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

func TestHandlerDiscoversWorkspaceScopedModelsThroughSignedProtocol(t *testing.T) {
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	store, _ := OpenStore("", testSecret)
	source := &recordingModelDiscovery{results: map[string]ModelDiscovery{
		workspaceOne: {Status: ModelDiscoveryAvailable, Models: []ModelOption{{ID: "gpt-5.6-sol", Label: "GPT-5.6-Sol", Default: true}}},
		workspaceTwo: {Status: ModelDiscoveryAvailable, Models: []ModelOption{{ID: "gpt-5.5", Label: "GPT-5.5"}}},
	}}
	handler, err := NewHandlerWithDiscovery(testSecret, store, fixedStatus{}, source, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	response := serve(t, handler, ModelsPath, map[string]any{
		"protocol_version": protocol.Version, "workspace_key": workspaceOne, "adapter_key": CodexAdapterKey,
	}, now, testSecret)
	if response.Code != http.StatusOK || strings.Contains(response.Body.String(), "sk-") || strings.Contains(response.Body.String(), "raw-command-output") {
		t.Fatalf("unexpected model discovery response: status=%d body=%s", response.Code, response.Body.String())
	}
	var payload struct {
		ProtocolVersion string        `json:"protocol_version"`
		WorkspaceKey    string        `json:"workspace_key"`
		AdapterKey      string        `json:"adapter_key"`
		Status          string        `json:"status"`
		CheckedAt       string        `json:"checked_at"`
		Models          []ModelOption `json:"models"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.ProtocolVersion != protocol.Version || payload.WorkspaceKey != workspaceOne || payload.AdapterKey != CodexAdapterKey ||
		payload.Status != ModelDiscoveryAvailable || payload.CheckedAt != now.Format(time.RFC3339Nano) ||
		len(payload.Models) != 1 || payload.Models[0].ID != "gpt-5.6-sol" || !payload.Models[0].Default {
		t.Fatalf("unexpected model discovery payload: %#v", payload)
	}
	var exact map[string]any
	if json.Unmarshal(response.Body.Bytes(), &exact) != nil || len(exact) != 6 {
		t.Fatalf("model discovery response has unexpected fields: %s", response.Body.String())
	}
	other := serve(t, handler, ModelsPath, map[string]any{
		"protocol_version": protocol.Version, "workspace_key": workspaceTwo, "adapter_key": CodexAdapterKey,
	}, now, testSecret)
	if other.Code != http.StatusOK || !strings.Contains(other.Body.String(), "gpt-5.5") || strings.Contains(other.Body.String(), "gpt-5.6-sol") {
		t.Fatalf("workspace model discovery crossed isolation boundary: %s", other.Body.String())
	}
	if !strings.EqualFold(strings.Join(source.workspaces, ","), workspaceOne+","+workspaceTwo) || len(source.adapters) != 2 {
		t.Fatalf("discovery source received unexpected scope: workspaces=%v adapters=%v", source.workspaces, source.adapters)
	}
}

func TestHandlerReturnsBoundedDiscoveryStatusesAndRejectsInvalidSourceData(t *testing.T) {
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	for name, result := range map[string]ModelDiscovery{
		"unsupported":    {Status: ModelDiscoveryUnsupported},
		"failed":         {Status: ModelDiscoveryFailed},
		"invalid status": {Status: "unknown"},
		"duplicate":      {Status: ModelDiscoveryAvailable, Models: []ModelOption{{ID: "gpt", Label: "GPT"}, {ID: "gpt", Label: "GPT again"}}},
		"control":        {Status: ModelDiscoveryAvailable, Models: []ModelOption{{ID: "gpt", Label: "GPT\nsecret"}}},
	} {
		t.Run(name, func(t *testing.T) {
			store, _ := OpenStore("", testSecret)
			source := &recordingModelDiscovery{results: map[string]ModelDiscovery{workspaceOne: result}}
			handler, err := NewHandlerWithDiscovery(testSecret, store, fixedStatus{}, source, func() time.Time { return now })
			if err != nil {
				t.Fatal(err)
			}
			response := serve(t, handler, ModelsPath, map[string]any{
				"protocol_version": protocol.Version, "workspace_key": workspaceOne, "adapter_key": CursorAdapterKey,
			}, now, testSecret)
			if response.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
			}
			var payload struct {
				Status string        `json:"status"`
				Models []ModelOption `json:"models"`
			}
			expectedStatus := result.Status
			if !validModelDiscovery(result) {
				expectedStatus = ModelDiscoveryFailed
			}
			if json.Unmarshal(response.Body.Bytes(), &payload) != nil || payload.Status != expectedStatus {
				t.Fatalf("unexpected status response: %s", response.Body.String())
			}
			if result.Status == ModelDiscoveryAvailable || result.Status == "unknown" {
				if payload.Status != ModelDiscoveryFailed {
					t.Fatalf("invalid source data was not failed closed: %s", response.Body.String())
				}
			}
			if payload.Status != ModelDiscoveryAvailable && len(payload.Models) != 0 {
				t.Fatalf("non-available response returned models: %s", response.Body.String())
			}
		})
	}

	store, _ := OpenStore("", testSecret)
	defaultHandler, err := NewHandler(testSecret, store, fixedStatus{}, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	response := serve(t, defaultHandler, ModelsPath, map[string]any{
		"protocol_version": protocol.Version, "workspace_key": workspaceOne, "adapter_key": ClaudeAdapterKey,
	}, now, testSecret)
	var unsupported struct {
		Status string        `json:"status"`
		Models []ModelOption `json:"models"`
	}
	if response.Code != http.StatusOK || json.Unmarshal(response.Body.Bytes(), &unsupported) != nil || unsupported.Status != ModelDiscoveryUnsupported || unsupported.Models == nil {
		t.Fatalf("default discovery source was not bounded unsupported/empty: status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestHandlerModelsRequiresSignedExactWorkspaceAndAdapterRequest(t *testing.T) {
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	store, _ := OpenStore("", testSecret)
	source := &recordingModelDiscovery{results: map[string]ModelDiscovery{workspaceOne: {Status: ModelDiscoveryUnsupported}}}
	handler, err := NewHandlerWithDiscovery(testSecret, store, fixedStatus{}, source, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	badSignature := serve(t, handler, ModelsPath, map[string]any{
		"protocol_version": protocol.Version, "workspace_key": workspaceOne, "adapter_key": CodexAdapterKey,
	}, now, []byte("wrong-provider-secret-that-is-at-least-32-bytes"))
	if badSignature.Code != http.StatusUnauthorized {
		t.Fatalf("bad model signature status=%d", badSignature.Code)
	}
	for name, input := range map[string]map[string]any{
		"extra field":       {"protocol_version": protocol.Version, "workspace_key": workspaceOne, "adapter_key": CodexAdapterKey, "extra": true},
		"invalid workspace": {"protocol_version": protocol.Version, "workspace_key": "not-a-workspace", "adapter_key": CodexAdapterKey},
		"invalid adapter":   {"protocol_version": protocol.Version, "workspace_key": workspaceOne, "adapter_key": "bad-adapter-key"},
	} {
		t.Run(name, func(t *testing.T) {
			response := serve(t, handler, ModelsPath, input, now, testSecret)
			if response.Code != http.StatusUnprocessableEntity {
				t.Fatalf("expected invalid model request, status=%d body=%s", response.Code, response.Body.String())
			}
		})
	}
	unknown := serve(t, handler, ModelsPath, map[string]any{
		"protocol_version": protocol.Version, "workspace_key": workspaceOne, "adapter_key": "future_provider",
	}, now, testSecret)
	var unknownPayload struct {
		AdapterKey string        `json:"adapter_key"`
		Status     string        `json:"status"`
		Models     []ModelOption `json:"models"`
	}
	if unknown.Code != http.StatusOK || json.Unmarshal(unknown.Body.Bytes(), &unknownPayload) != nil ||
		unknownPayload.AdapterKey != "future_provider" || unknownPayload.Status != ModelDiscoveryUnsupported || unknownPayload.Models == nil {
		t.Fatalf("valid unknown adapter was not bounded unsupported/empty: status=%d body=%s", unknown.Code, unknown.Body.String())
	}
	if len(source.workspaces) != 0 {
		t.Fatalf("valid unknown adapter invoked discovery source: workspaces=%v", source.workspaces)
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
