package websearch

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Hosted search providers keep the same bounded contract as SearXNG: one HTTPS
// request per search, no redirects, a bounded JSON body, and normalised results.
// The API key stays on the runner and is sent only to the fixed provider host.
const (
	ExaKey        = "exa"
	TavilyKey     = "tavily"
	exaEndpoint   = "https://api.exa.ai/search"
	tavilyURL     = "https://api.tavily.com/search"
	excerptBytes  = 600
	hostedTimeout = 10 * time.Second
)

type hostedRequest struct {
	url         string
	authorize   func(*http.Request, string)
	body        func(query string, maximum int) any
	parse       func([]byte, int) ([]Result, error)
	costPerCall int
}

type Hosted struct {
	key      string
	apiKey   string
	endpoint *url.URL
	client   *http.Client
	spec     hostedRequest
}

// NewExa configures the Exa search API. address overrides the fixed endpoint
// only for loopback test servers.
func NewExa(apiKey, address string, client *http.Client) (*Hosted, error) {
	return newHosted(ExaKey, apiKey, address, client, hostedRequest{
		url: exaEndpoint,
		authorize: func(request *http.Request, key string) {
			request.Header.Set("x-api-key", key)
		},
		body: func(query string, maximum int) any {
			return map[string]any{
				"query": query, "numResults": maximum, "type": "auto",
				"contents": map[string]any{"text": map[string]any{"maxCharacters": excerptBytes}},
			}
		},
		parse: func(body []byte, maximum int) ([]Result, error) {
			var payload struct {
				Results []struct {
					Title     string `json:"title"`
					URL       string `json:"url"`
					Published string `json:"publishedDate"`
					Text      string `json:"text"`
				} `json:"results"`
			}
			if err := decodeStrict(body, &payload); err != nil {
				return nil, err
			}
			results := make([]Result, 0, min(maximum, len(payload.Results)))
			for _, item := range payload.Results {
				results = append(results, Result{
					Title: item.Title, URL: item.URL, Excerpt: truncate(item.Text), PublishedAt: parseTime(item.Published),
				})
				if len(results) == maximum {
					break
				}
			}
			return results, nil
		},
		costPerCall: 1,
	})
}

// NewTavily configures the Tavily search API with the basic search depth.
func NewTavily(apiKey, address string, client *http.Client) (*Hosted, error) {
	return newHosted(TavilyKey, apiKey, address, client, hostedRequest{
		url: tavilyURL,
		authorize: func(request *http.Request, key string) {
			request.Header.Set("Authorization", "Bearer "+key)
		},
		body: func(query string, maximum int) any {
			return map[string]any{
				"query": query, "max_results": maximum, "search_depth": "basic",
				"include_answer": false, "include_raw_content": false, "include_images": false,
			}
		},
		parse: func(body []byte, maximum int) ([]Result, error) {
			var payload struct {
				Results []struct {
					Title     string `json:"title"`
					URL       string `json:"url"`
					Content   string `json:"content"`
					Published string `json:"published_date"`
				} `json:"results"`
			}
			if err := decodeStrict(body, &payload); err != nil {
				return nil, err
			}
			results := make([]Result, 0, min(maximum, len(payload.Results)))
			for _, item := range payload.Results {
				results = append(results, Result{
					Title: item.Title, URL: item.URL, Excerpt: truncate(item.Content), PublishedAt: parseTime(item.Published),
				})
				if len(results) == maximum {
					break
				}
			}
			return results, nil
		},
		costPerCall: 1,
	})
}

func newHosted(key, apiKey, address string, client *http.Client, spec hostedRequest) (*Hosted, error) {
	apiKey = strings.TrimSpace(apiKey)
	if apiKey == "" || len(apiKey) > 512 || strings.ContainsAny(apiKey, "\r\n\t ") {
		return nil, fmt.Errorf("%s API key is required", key)
	}
	if address == "" {
		address = spec.url
	}
	endpoint, err := url.Parse(address)
	if err != nil || endpoint.Host == "" || endpoint.User != nil || endpoint.RawQuery != "" || endpoint.Fragment != "" ||
		(endpoint.Scheme != "https" && !(endpoint.Scheme == "http" && loopback(endpoint.Hostname()))) {
		return nil, fmt.Errorf("%s endpoint must be HTTPS or loopback HTTP", key)
	}
	if client == nil {
		client = &http.Client{Timeout: hostedTimeout, CheckRedirect: func(*http.Request, []*http.Request) error {
			return errors.New("search provider redirects are not allowed")
		}}
	}
	return &Hosted{key: key, apiKey: apiKey, endpoint: endpoint, client: client, spec: spec}, nil
}

func (provider *Hosted) Key() string { return provider.key }

func (provider *Hosted) Search(ctx context.Context, query string, maximum int) ([]Result, int, error) {
	payload, err := json.Marshal(provider.spec.body(query, maximum))
	if err != nil {
		return nil, 0, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, provider.endpoint.String(), bytes.NewReader(payload))
	if err != nil {
		return nil, 0, err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")
	provider.spec.authorize(request, provider.apiKey)
	response, err := provider.client.Do(request)
	if err != nil {
		return nil, 0, fmt.Errorf("search provider unavailable: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK || !strings.HasPrefix(response.Header.Get("Content-Type"), "application/json") {
		return nil, 0, fmt.Errorf("search provider returned HTTP %d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maximumProviderBody+1))
	if err != nil || len(body) > maximumProviderBody {
		return nil, 0, errors.New("search provider response exceeds limit")
	}
	results, err := provider.spec.parse(body, maximum)
	if err != nil {
		return nil, 0, err
	}
	normalized, err := Normalize(results, maximum)
	return normalized, provider.spec.costPerCall, err
}

func decodeStrict(body []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(body))
	if decoder.Decode(target) != nil {
		return errors.New("search provider returned malformed JSON")
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("search provider returned malformed JSON")
	}
	return nil
}

func parseTime(value string) *time.Time {
	for _, layout := range []string{time.RFC3339, "2006-01-02"} {
		if parsed, err := time.Parse(layout, value); err == nil {
			parsed = parsed.UTC()
			return &parsed
		}
	}
	return nil
}

func truncate(value string) string {
	value = strings.Join(strings.Fields(value), " ")
	if len(value) <= excerptBytes {
		return value
	}
	cut := excerptBytes
	for cut > 0 && !isBoundary(value[cut]) {
		cut--
	}
	if cut == 0 {
		cut = excerptBytes
	}
	return strings.TrimSpace(value[:cut])
}

func isBoundary(character byte) bool { return character == ' ' }
