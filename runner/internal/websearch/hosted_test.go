package websearch

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestExaSendsBoundedRequestAndNormalizesResults(t *testing.T) {
	var received map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost || request.Header.Get("x-api-key") != "exa-test-key" ||
			request.Header.Get("Content-Type") != "application/json" {
			t.Fatalf("unexpected request %s %v", request.Method, request.Header)
		}
		if err := json.NewDecoder(request.Body).Decode(&received); err != nil {
			t.Fatal(err)
		}
		response.Header().Set("Content-Type", "application/json")
		_, _ = response.Write([]byte(`{"results":[
			{"title":" Status page ","url":"https://status.example.com/incident","publishedDate":"2026-08-20T10:00:00.000Z","text":"Service   restored after the\nincident."},
			{"title":"Duplicate","url":"https://status.example.com/incident","text":"again"},
			{"title":"Insecure","url":"http://insecure.example.com/","text":"dropped"}
		],"costDollars":{"total":0.005}}`))
	}))
	defer server.Close()

	provider, err := NewExa("exa-test-key", server.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	if provider.Key() != ExaKey {
		t.Fatalf("unexpected key %s", provider.Key())
	}
	results, cost, err := provider.Search(context.Background(), "service status", 5)
	if err == nil {
		t.Fatalf("expected the insecure link to fail normalisation, got %#v", results)
	}
	if received["query"] != "service status" || received["numResults"] != float64(5) {
		t.Fatalf("unexpected request body %#v", received)
	}
	_ = cost

	secure := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Content-Type", "application/json")
		_, _ = response.Write([]byte(`{"results":[
			{"title":" Status page ","url":"https://status.example.com/incident","publishedDate":"2026-08-20","text":"Service   restored after the\nincident."},
			{"title":"Duplicate","url":"https://status.example.com/incident","text":"again"}
		]}`))
	}))
	defer secure.Close()
	provider, _ = NewExa("exa-test-key", secure.URL, nil)
	results, cost, err = provider.Search(context.Background(), "service status", 5)
	if err != nil || cost != 1 || len(results) != 1 {
		t.Fatalf("results=%#v cost=%d err=%v", results, cost, err)
	}
	if results[0].Rank != 1 || results[0].Title != "Status page" || results[0].Excerpt != "Service restored after the incident." ||
		results[0].PublishedAt == nil || results[0].PublishedAt.Format("2006-01-02") != "2026-08-20" {
		t.Fatalf("unexpected result %#v", results[0])
	}
}

func TestTavilySendsBearerKeyAndBoundsExcerpts(t *testing.T) {
	long := strings.Repeat("word ", 300)
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Header.Get("Authorization") != "Bearer tavily-test-key" {
			t.Fatalf("missing bearer key: %q", request.Header.Get("Authorization"))
		}
		var body map[string]any
		_ = json.NewDecoder(request.Body).Decode(&body)
		if body["max_results"] != float64(3) || body["search_depth"] != "basic" || body["include_answer"] != false {
			t.Fatalf("unexpected body %#v", body)
		}
		response.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(response).Encode(map[string]any{"results": []map[string]any{
			{"title": "Docs", "url": "https://docs.example.com/a", "content": long, "published_date": "2026-08-01T00:00:00Z"},
			{"title": "Second", "url": "https://docs.example.com/b", "content": "short"},
			{"title": "Third", "url": "https://docs.example.com/c", "content": "third"},
			{"title": "Fourth", "url": "https://docs.example.com/d", "content": "never returned"},
		}})
	}))
	defer server.Close()

	provider, err := NewTavily("tavily-test-key", server.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	results, cost, err := provider.Search(context.Background(), "example docs", 3)
	if err != nil || cost != 1 || len(results) != 3 {
		t.Fatalf("results=%d cost=%d err=%v", len(results), cost, err)
	}
	if len(results[0].Excerpt) > excerptBytes || strings.HasSuffix(results[0].Excerpt, " ") || results[2].Rank != 3 {
		t.Fatalf("unexpected excerpt bound %d or rank %d", len(results[0].Excerpt), results[2].Rank)
	}
}

func TestHostedProvidersRejectBadConfigurationAndResponses(t *testing.T) {
	if _, err := NewExa("", "", nil); err == nil {
		t.Fatal("expected a missing key to fail")
	}
	if _, err := NewTavily("key with space", "", nil); err == nil {
		t.Fatal("expected a malformed key to fail")
	}
	if _, err := NewExa("key", "http://search.example.com/", nil); err == nil {
		t.Fatal("expected cleartext non-loopback endpoint to fail")
	}
	if _, err := NewExa("key", "https://user:pass@api.exa.ai/search", nil); err == nil {
		t.Fatal("expected credentials in the endpoint to fail")
	}

	for name, handler := range map[string]http.HandlerFunc{
		"status": func(response http.ResponseWriter, _ *http.Request) { response.WriteHeader(http.StatusTooManyRequests) },
		"redirect": func(response http.ResponseWriter, _ *http.Request) {
			response.Header().Set("Location", "https://elsewhere.example.com/")
			response.WriteHeader(http.StatusFound)
		},
		"trailing": func(response http.ResponseWriter, _ *http.Request) {
			response.Header().Set("Content-Type", "application/json")
			_, _ = response.Write([]byte(`{"results":[]}{"more":true}`))
		},
		"oversized": func(response http.ResponseWriter, _ *http.Request) {
			response.Header().Set("Content-Type", "application/json")
			_, _ = response.Write([]byte(`{"results":[{"title":"` + strings.Repeat("x", maximumProviderBody) + `","url":"https://a.example.com/"}]}`))
		},
	} {
		server := httptest.NewServer(handler)
		provider, err := NewTavily("tavily-test-key", server.URL, nil)
		if err != nil {
			t.Fatal(err)
		}
		if _, _, err := provider.Search(context.Background(), "query", 3); err == nil {
			t.Fatalf("%s: expected an error", name)
		}
		server.Close()
	}
}
