package websearch

import (
	"context"
	"errors"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"time"
)

const Path = "/v1/tools/web-search"

var (
	ErrInvalidRequest = errors.New("invalid web search request")
	workspacePattern  = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	keyPattern        = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}$`)
)

type Request struct {
	ProtocolVersion string `json:"protocol_version"`
	WorkspaceKey    string `json:"workspace_key"`
	RequestKey      string `json:"request_key"`
	Query           string `json:"query"`
	MaxResults      int    `json:"max_results"`
}

type Result struct {
	Rank        int        `json:"rank"`
	Title       string     `json:"title"`
	URL         string     `json:"url"`
	Excerpt     string     `json:"excerpt"`
	PublishedAt *time.Time `json:"published_at"`
}

type Response struct {
	ProtocolVersion string    `json:"protocol_version"`
	WorkspaceKey    string    `json:"workspace_key"`
	RequestKey      string    `json:"request_key"`
	Query           string    `json:"query"`
	ProviderKey     string    `json:"provider_key"`
	PolicyDecision  string    `json:"policy_decision"`
	CostUnits       int       `json:"cost_units"`
	RetrievedAt     time.Time `json:"retrieved_at"`
	Results         []Result  `json:"results"`
}

type Provider interface {
	Key() string
	Search(context.Context, string, int) ([]Result, int, error)
}

func (request Request) Validate(protocolVersion string) error {
	query := strings.TrimSpace(request.Query)
	if request.ProtocolVersion != protocolVersion || !workspacePattern.MatchString(request.WorkspaceKey) ||
		!keyPattern.MatchString(request.RequestKey) || query != request.Query || len(query) < 2 || len(query) > 500 ||
		request.MaxResults < 1 || request.MaxResults > 10 {
		return ErrInvalidRequest
	}
	return nil
}

func (response Response) Validate(protocolVersion string) error {
	request := Request{
		ProtocolVersion: response.ProtocolVersion, WorkspaceKey: response.WorkspaceKey,
		RequestKey: response.RequestKey, Query: response.Query, MaxResults: max(1, len(response.Results)),
	}
	if request.Validate(protocolVersion) != nil || len(response.Results) > 10 || !keyPattern.MatchString(response.ProviderKey) ||
		response.PolicyDecision != "allowed" || response.CostUnits < 0 || response.RetrievedAt.IsZero() {
		return ErrInvalidRequest
	}
	normalized, err := Normalize(append([]Result(nil), response.Results...), 10)
	if err != nil || len(normalized) != len(response.Results) {
		return ErrInvalidRequest
	}
	for index, result := range response.Results {
		if result.Rank != index+1 || normalized[index].Title != result.Title || normalized[index].Excerpt != result.Excerpt {
			return ErrInvalidRequest
		}
	}
	return nil
}

func Normalize(results []Result, maximum int) ([]Result, error) {
	if len(results) > maximum {
		results = results[:maximum]
	}
	normalized := make([]Result, 0, len(results))
	seen := make(map[string]struct{}, len(results))
	for _, result := range results {
		parsed, err := url.Parse(result.URL)
		if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || parsed.Fragment != "" ||
			len(result.URL) > 2048 || len(strings.TrimSpace(result.Title)) == 0 || len(result.Title) > 500 ||
			len(result.Excerpt) > 4000 {
			return nil, ErrInvalidRequest
		}
		if _, duplicate := seen[result.URL]; duplicate {
			continue
		}
		seen[result.URL] = struct{}{}
		result.Rank = len(normalized) + 1
		result.Title = strings.TrimSpace(result.Title)
		result.Excerpt = strings.TrimSpace(result.Excerpt)
		normalized = append(normalized, result)
	}
	sort.SliceStable(normalized, func(i, j int) bool { return normalized[i].Rank < normalized[j].Rank })
	return normalized, nil
}
