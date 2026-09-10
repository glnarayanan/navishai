package websearch

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

var searchNow = time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)

type fixtureProvider struct{ calls int }

func (provider *fixtureProvider) Key() string { return "fixture" }
func (provider *fixtureProvider) Search(context.Context, string, int) ([]Result, int, error) {
	provider.calls++
	published := searchNow.Add(-24 * time.Hour)
	return []Result{{Title: "Current status", URL: "https://status.example.com/event", Excerpt: "Service restored.", PublishedAt: &published}}, 2, nil
}

func TestHandlerAuthenticatesNormalizesAndReplays(t *testing.T) {
	provider := &fixtureProvider{}
	store, err := OpenStore(filepath.Join(t.TempDir(), "searches.json"))
	if err != nil {
		t.Fatal(err)
	}
	handler, err := NewHandler([]byte("runner-test-secret-that-is-at-least-32-bytes"), provider, store, func() time.Time { return searchNow })
	if err != nil {
		t.Fatal(err)
	}
	body := requestBody(t, "search:one", "example service status")
	first := perform(t, handler, body)
	second := perform(t, handler, body)
	if first.Code != http.StatusOK || second.Header().Get("X-NavishAI-Idempotent-Replay") != "true" || provider.calls != 1 {
		t.Fatalf("first=%d second=%d calls=%d", first.Code, second.Code, provider.calls)
	}
	var response Response
	if err := json.Unmarshal(first.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.ProviderKey != "fixture" || response.PolicyDecision != "allowed" || response.CostUnits != 2 || response.Results[0].Rank != 1 {
		t.Fatalf("unexpected response %#v", response)
	}

	changed := perform(t, handler, requestBody(t, "search:one", "changed query"))
	if changed.Code != http.StatusConflict {
		t.Fatalf("expected conflict, got %d", changed.Code)
	}
}

func TestHandlerRejectsUnknownFieldsAndBadAuthentication(t *testing.T) {
	store, _ := OpenStore("")
	handler, _ := NewHandler([]byte("runner-test-secret-that-is-at-least-32-bytes"), &fixtureProvider{}, store, func() time.Time { return searchNow })
	body := strings.TrimSuffix(string(requestBody(t, "search:one", "status query")), "}") + `,"unknown":true}`
	request := httptest.NewRequest(http.MethodPost, Path, strings.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("expected unauthorized, got %d", response.Code)
	}

	signed := perform(t, handler, []byte(body))
	if signed.Code != http.StatusUnprocessableEntity {
		t.Fatalf("expected invalid request, got %d", signed.Code)
	}
}

func TestSearXNGUsesBoundedJSONContract(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Query().Get("q") != "service status" || request.URL.Query().Get("format") != "json" {
			t.Fatalf("unexpected query %s", request.URL.RawQuery)
		}
		response.Header().Set("Content-Type", "application/json")
		_, _ = response.Write([]byte(`{"results":[{"title":" Status update ","url":"https://status.example.com/event","content":" Restored ","publishedDate":"2026-08-23T12:00:00Z"},{"title":"Duplicate","url":"https://status.example.com/event","content":"Same"}]}`))
	}))
	defer server.Close()
	provider, err := NewSearXNG(server.URL, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	results, cost, err := provider.Search(context.Background(), "service status", 5)
	if err != nil || cost != 1 || len(results) != 1 || results[0].PublishedAt == nil || !results[0].PublishedAt.Equal(searchNow.Add(-24*time.Hour)) {
		t.Fatalf("results=%#v cost=%d err=%v", results, cost, err)
	}
	if results[0].Title != "Status update" || results[0].Excerpt != "Restored" || results[0].Rank != 1 {
		t.Fatalf("unexpected normalized result %#v", results[0])
	}
}

func TestSearXNGRejectsTrailingJSONAndStoreRejectsInvalidRecords(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		response.Header().Set("Content-Type", "application/json")
		_, _ = response.Write([]byte(`{"results":[]} {"trailing":true}`))
	}))
	defer server.Close()
	provider, err := NewSearXNG(server.URL, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := provider.Search(context.Background(), "service status", 5); err == nil {
		t.Fatal("expected trailing provider JSON to fail")
	}

	path := filepath.Join(t.TempDir(), "invalid-searches.json")
	if err := os.WriteFile(path, []byte(`{"search:one":{"request_digest":"bad","response":{}}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenStore(path); err == nil {
		t.Fatal("expected invalid stored response to fail closed")
	}
}

func requestBody(t *testing.T, key, query string) []byte {
	t.Helper()
	body, err := json.Marshal(Request{
		ProtocolVersion: protocol.Version, WorkspaceKey: "c9bb966b-1fe9-4304-bd51-404e4fd9a09c",
		RequestKey: key, Query: query, MaxResults: 5,
	})
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func perform(t *testing.T, handler http.Handler, body []byte) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(http.MethodPost, Path, strings.NewReader(string(body)))
	request.Header.Set("Content-Type", "application/json")
	timestamp := strconv.FormatInt(searchNow.Unix(), 10)
	request.Header.Set("X-NavishAI-Timestamp", timestamp)
	signature, err := protocol.Sign([]byte("runner-test-secret-that-is-at-least-32-bytes"), timestamp, http.MethodPost, Path, body)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("X-NavishAI-Signature", signature)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}

type namedProvider struct {
	fixtureProvider
	key string
}

func (provider *namedProvider) Key() string { return provider.key }

func TestRegistrySelectionAndReplaySurviveProviderRemoval(t *testing.T) {
	store, _ := OpenStore("")
	first := &namedProvider{key: "first"}
	second := &namedProvider{key: "second"}
	secret := []byte("runner-test-secret-that-is-at-least-32-bytes")
	handler, err := NewRegistryHandler(secret, []Provider{first, second}, "first", store, func() time.Time { return searchNow })
	if err != nil {
		t.Fatal(err)
	}
	var input Request
	_ = json.Unmarshal(requestBody(t, "search:selected", "public query"), &input)
	input.ProviderKey = "second"
	body, _ := json.Marshal(input)
	response := perform(t, handler, body)
	if response.Code != http.StatusOK || second.calls != 1 || first.calls != 0 {
		t.Fatalf("selection: %d calls=%d/%d", response.Code, first.calls, second.calls)
	}
	changed, _ := NewRegistryHandler(secret, []Provider{first}, "first", store, func() time.Time { return searchNow })
	replay := perform(t, changed, body)
	if replay.Code != http.StatusOK || replay.Header().Get("X-NavishAI-Idempotent-Replay") != "true" {
		t.Fatalf("replay: %s", replay.Body)
	}
	input.ProviderKey = "first"
	body, _ = json.Marshal(input)
	if result := perform(t, changed, body); result.Code != http.StatusConflict {
		t.Fatalf("provider conflict: %d", result.Code)
	}
	input.RequestKey = "search:unavailable"
	input.ProviderKey = "missing"
	body, _ = json.Marshal(input)
	if result := perform(t, handler, body); result.Code != http.StatusServiceUnavailable {
		t.Fatalf("unavailable: %d", result.Code)
	}
}

func TestCatalogRequiresSignedWorkspaceRequest(t *testing.T) {
	store, _ := OpenStore("")
	secret := []byte("runner-test-secret-that-is-at-least-32-bytes")
	handler, _ := NewRegistryHandler(secret, []Provider{&namedProvider{key: "second"}, &namedProvider{key: "first"}}, "first", store, func() time.Time { return searchNow })
	body := []byte(`{"protocol_version":"v1","workspace_key":"c9bb966b-1fe9-4304-bd51-404e4fd9a09c"}`)
	request := httptest.NewRequest(http.MethodPost, CatalogPath, strings.NewReader(string(body)))
	request.Header.Set("Content-Type", "application/json")
	unauthorized := httptest.NewRecorder()
	handler.ServeHTTP(unauthorized, request)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatal(unauthorized.Code)
	}
	request = httptest.NewRequest(http.MethodPost, CatalogPath, strings.NewReader(string(body)))
	request.Header.Set("Content-Type", "application/json")
	timestamp := strconv.FormatInt(searchNow.Unix(), 10)
	signature, _ := protocol.Sign(secret, timestamp, http.MethodPost, CatalogPath, body)
	request.Header.Set("X-NavishAI-Timestamp", timestamp)
	request.Header.Set("X-NavishAI-Signature", signature)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"provider_keys":["first","second"]`) {
		t.Fatalf("catalog: %d %s", response.Code, response.Body)
	}
}
