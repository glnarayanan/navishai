package websearch

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	maximumProviderBody = 1024 * 1024
	SearXNGKey          = "searxng"
)

type SearXNG struct {
	endpoint *url.URL
	client   *http.Client
}

func NewSearXNG(address string, client *http.Client) (*SearXNG, error) {
	endpoint, err := url.Parse(address)
	if err != nil || endpoint.Host == "" || endpoint.User != nil || endpoint.RawQuery != "" || endpoint.Fragment != "" ||
		(endpoint.Scheme != "https" && !(endpoint.Scheme == "http" && loopback(endpoint.Hostname()))) {
		return nil, errors.New("SearXNG endpoint must be HTTPS or loopback HTTP")
	}
	if client == nil {
		client = &http.Client{Timeout: 8 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error {
			return errors.New("SearXNG redirects are not allowed")
		}}
	}
	return &SearXNG{endpoint: endpoint, client: client}, nil
}

func (provider *SearXNG) Key() string { return SearXNGKey }

func (provider *SearXNG) Search(ctx context.Context, query string, maximum int) ([]Result, int, error) {
	endpoint := *provider.endpoint
	values := endpoint.Query()
	values.Set("q", query)
	values.Set("format", "json")
	endpoint.RawQuery = values.Encode()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return nil, 0, err
	}
	request.Header.Set("Accept", "application/json")
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
	var payload struct {
		Results []struct {
			Title     string `json:"title"`
			URL       string `json:"url"`
			Content   string `json:"content"`
			Published string `json:"publishedDate"`
		} `json:"results"`
	}
	decoder := json.NewDecoder(strings.NewReader(string(body)))
	if decoder.Decode(&payload) != nil {
		return nil, 0, errors.New("search provider returned malformed JSON")
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return nil, 0, errors.New("search provider returned malformed JSON")
	}
	results := make([]Result, 0, min(maximum, len(payload.Results)))
	for _, item := range payload.Results {
		var publishedAt *time.Time
		if value, err := time.Parse(time.RFC3339, item.Published); err == nil {
			value = value.UTC()
			publishedAt = &value
		}
		results = append(results, Result{Title: item.Title, URL: item.URL, Excerpt: item.Content, PublishedAt: publishedAt})
		if len(results) == maximum {
			break
		}
	}
	normalized, err := Normalize(results, maximum)
	return normalized, 1, err
}

func loopback(host string) bool {
	if host == "localhost" {
		return true
	}
	address := net.ParseIP(host)
	return address != nil && address.IsLoopback()
}
