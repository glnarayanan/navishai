package providerapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	clientTimeout        = 15 * time.Second
	maxAPIKeyBytes       = 16 * 1024
	maxModelBytes        = 200
	maxPromptBytes       = 64 * 1024
	maxRequestBodyBytes  = 128 * 1024
	maxResponseBodyBytes = 2 * 1024 * 1024
	maxOutputTextBytes   = 100 * 1024
	maxModelOptions      = 100
	maxOutputTokens      = 16 * 1024
	maxUsageTokens       = 10_000_000

	openAIBaseURL    = "https://api.openai.com"
	anthropicBaseURL = "https://api.anthropic.com"
	anthropicVersion = "2023-06-01"
)

type ErrorCode string

const (
	CodeInvalidInput        ErrorCode = "invalid_input"
	CodeUnsupportedProvider ErrorCode = "unsupported_provider"
	CodeTransport           ErrorCode = "transport_error"
	CodeTimeout             ErrorCode = "timeout"
	CodeCanceled            ErrorCode = "canceled"
	CodeRedirectRejected    ErrorCode = "redirect_rejected"
	CodeAuthentication      ErrorCode = "authentication_failed"
	CodeUnavailable         ErrorCode = "provider_unavailable"
	CodeHTTPStatus          ErrorCode = "http_status"
	CodeRequestTooLarge     ErrorCode = "request_too_large"
	CodeResponseTooLarge    ErrorCode = "response_too_large"
	CodeMalformedResponse   ErrorCode = "malformed_response"
	CodeIncompleteResponse  ErrorCode = "incomplete_response"
)

// Error is a sanitized provider API error. It never retains provider response
// text, request bodies, credentials, or endpoint details.
type Error struct {
	Code       ErrorCode
	StatusCode int
}

func (err *Error) Error() string {
	if err == nil {
		return "provider API error"
	}
	if err.StatusCode != 0 {
		return fmt.Sprintf("provider API %s (status %d)", err.Code, err.StatusCode)
	}
	return "provider API " + string(err.Code)
}

type doer interface {
	Do(*http.Request) (*http.Response, error)
}

type Client struct {
	doer doer
}

type ModelOption struct {
	ID      string
	Label   string
	Default bool
}

type GenerationResult struct {
	Text         string
	InputTokens  int
	OutputTokens int
}

// New creates a client with the fixed bounded HTTPS policy. Production callers
// cannot replace its transport, proxy, timeout, or redirect policy.
func New() *Client {
	return &Client{doer: newHTTPClient(nil)}
}

func newWithDoer(injected doer) *Client {
	return &Client{doer: injected}
}

func newWithTransport(transport http.RoundTripper) *Client {
	return newWithDoer(newHTTPClient(transport))
}

func (client *Client) DiscoverModels(ctx context.Context, adapterKey, apiKey string) ([]ModelOption, error) {
	spec, ok := providerSpecFor(adapterKey)
	if !ok {
		return nil, providerError(CodeUnsupportedProvider, 0)
	}
	if err := validateAPIKey(apiKey); err != nil {
		return nil, err
	}
	body, err := client.do(ctx, http.MethodGet, spec, spec.modelsPath, apiKey, nil)
	if err != nil {
		return nil, err
	}
	return parseModels(spec.kind, body)
}

func (client *Client) Generate(ctx context.Context, adapterKey, apiKey, model, prompt string, outputTokens int) (GenerationResult, error) {
	spec, ok := providerSpecFor(adapterKey)
	if !ok {
		return GenerationResult{}, providerError(CodeUnsupportedProvider, 0)
	}
	if err := validateAPIKey(apiKey); err != nil {
		return GenerationResult{}, err
	}
	if err := validateModel(model); err != nil {
		return GenerationResult{}, err
	}
	if !validPrompt(prompt) {
		return GenerationResult{}, providerError(CodeInvalidInput, 0)
	}
	if outputTokens <= 0 || outputTokens > maxOutputTokens {
		return GenerationResult{}, providerError(CodeInvalidInput, 0)
	}

	var requestBody any
	if spec.kind == providerKindOpenAI {
		requestBody = openAIRequest{Model: model, Input: prompt, Store: false, MaxOutputTokens: outputTokens}
	} else {
		requestBody = anthropicRequest{
			Model: model, MaxTokens: outputTokens,
			Messages: []anthropicMessage{{Role: "user", Content: prompt}},
		}
	}
	body, err := client.do(ctx, http.MethodPost, spec, spec.generatePath, apiKey, requestBody)
	if err != nil {
		return GenerationResult{}, err
	}
	if spec.kind == providerKindOpenAI {
		return parseOpenAIResponse(body)
	}
	return parseAnthropicResponse(body)
}

type providerKind string

const (
	providerKindOpenAI    providerKind = "openai"
	providerKindAnthropic providerKind = "anthropic"
)

type providerSpec struct {
	kind         providerKind
	baseURL      string
	modelsPath   string
	generatePath string
}

func providerSpecFor(adapterKey string) (providerSpec, bool) {
	switch adapterKey {
	case "codex_subscription":
		return providerSpec{
			kind: providerKindOpenAI, baseURL: openAIBaseURL,
			modelsPath: "/v1/models", generatePath: "/v1/responses",
		}, true
	case "claude_subscription":
		return providerSpec{
			kind: providerKindAnthropic, baseURL: anthropicBaseURL,
			modelsPath: "/v1/models?limit=100", generatePath: "/v1/messages",
		}, true
	default:
		return providerSpec{}, false
	}
}

func (client *Client) do(ctx context.Context, method string, spec providerSpec, path, apiKey string, payload any) ([]byte, error) {
	if ctx == nil {
		return nil, providerError(CodeInvalidInput, 0)
	}

	var requestBody []byte
	if payload != nil {
		encoded, err := json.Marshal(payload)
		if err != nil {
			return nil, providerError(CodeInvalidInput, 0)
		}
		if len(encoded) > maxRequestBodyBytes {
			return nil, providerError(CodeRequestTooLarge, 0)
		}
		requestBody = encoded
	}

	request, err := http.NewRequestWithContext(ctx, method, spec.baseURL+path, bytes.NewReader(requestBody))
	if err != nil {
		return nil, providerError(CodeInvalidInput, 0)
	}
	request.Header.Set("Accept", "application/json")
	if spec.kind == providerKindOpenAI {
		request.Header.Set("Authorization", "Bearer "+apiKey)
	} else {
		request.Header.Set("x-api-key", apiKey)
		request.Header.Set("anthropic-version", anthropicVersion)
	}
	if payload != nil {
		request.Header.Set("Content-Type", "application/json")
	}

	if client == nil || client.doer == nil {
		return nil, providerError(CodeTransport, 0)
	}
	response, err := client.doer.Do(request)
	if err != nil {
		if response != nil && response.Body != nil {
			_ = response.Body.Close()
		}
		return nil, classifyTransportError(err)
	}
	if response == nil {
		return nil, providerError(CodeTransport, 0)
	}
	if response.Body != nil {
		defer response.Body.Close()
	}

	if response.StatusCode >= 300 && response.StatusCode <= 399 {
		return nil, providerError(CodeRedirectRejected, response.StatusCode)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, providerError(codeForHTTPStatus(response.StatusCode), response.StatusCode)
	}
	if response.Body == nil || response.ContentLength > maxResponseBodyBytes {
		return nil, providerError(CodeResponseTooLarge, response.StatusCode)
	}
	mediaType, _, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		return nil, providerError(CodeMalformedResponse, response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBodyBytes+1))
	if err != nil {
		return nil, classifyTransportError(err)
	}
	if len(body) > maxResponseBodyBytes {
		return nil, providerError(CodeResponseTooLarge, response.StatusCode)
	}
	if !utf8.Valid(body) {
		return nil, providerError(CodeMalformedResponse, response.StatusCode)
	}
	return body, nil
}

func newHTTPClient(transport http.RoundTripper) *http.Client {
	if transport == nil {
		transport = &http.Transport{
			Proxy:                 nil,
			DialContext:           (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
			ForceAttemptHTTP2:     true,
			MaxIdleConns:          100,
			IdleConnTimeout:       90 * time.Second,
			TLSHandshakeTimeout:   10 * time.Second,
			ExpectContinueTimeout: 1 * time.Second,
		}
	}
	return &http.Client{
		Transport:     transport,
		Timeout:       clientTimeout,
		CheckRedirect: rejectRedirect,
	}
}

var errRedirectRejected = errors.New("provider API redirect rejected")

func rejectRedirect(*http.Request, []*http.Request) error {
	return errRedirectRejected
}

func classifyTransportError(err error) error {
	switch {
	case errors.Is(err, errRedirectRejected):
		return providerError(CodeRedirectRejected, 0)
	case errors.Is(err, context.Canceled):
		return providerError(CodeCanceled, 0)
	case errors.Is(err, context.DeadlineExceeded):
		return providerError(CodeTimeout, 0)
	}
	var networkError net.Error
	if errors.As(err, &networkError) && networkError.Timeout() {
		return providerError(CodeTimeout, 0)
	}
	return providerError(CodeTransport, 0)
}

func codeForHTTPStatus(statusCode int) ErrorCode {
	switch {
	case statusCode == http.StatusUnauthorized || statusCode == http.StatusForbidden:
		return CodeAuthentication
	case statusCode == http.StatusRequestTimeout || statusCode == http.StatusTooManyRequests || statusCode >= 500:
		return CodeUnavailable
	default:
		return CodeHTTPStatus
	}
}

func providerError(code ErrorCode, statusCode int) error {
	return &Error{Code: code, StatusCode: statusCode}
}

func validateAPIKey(value string) error {
	if !validBoundedText(value, maxAPIKeyBytes, false) {
		return providerError(CodeInvalidInput, 0)
	}
	return nil
}

func validateModel(value string) error {
	if !validBoundedText(value, maxModelBytes, false) || strings.TrimSpace(value) != value {
		return providerError(CodeInvalidInput, 0)
	}
	return nil
}

func validPrompt(value string) bool {
	return validBoundedText(value, maxPromptBytes, true) && strings.TrimSpace(value) != ""
}

func validBoundedText(value string, maximum int, allowNewlines bool) bool {
	if value == "" || len(value) > maximum || !utf8.ValidString(value) {
		return false
	}
	for _, runeValue := range value {
		if !unicode.IsControl(runeValue) {
			continue
		}
		if allowNewlines && (runeValue == '\n' || runeValue == '\r' || runeValue == '\t') {
			continue
		}
		return false
	}
	return true
}

func validModelText(value string) bool {
	return validBoundedText(value, maxModelBytes, false) && strings.TrimSpace(value) == value
}

func validOutputText(value string) bool {
	return validBoundedText(value, maxOutputTextBytes, true) && strings.TrimSpace(value) != ""
}

func validUsage(value int) bool {
	return value >= 0 && value <= maxUsageTokens
}

type openAIModelResponse struct {
	Object string `json:"object"`
	Data   []struct {
		ID string `json:"id"`
	} `json:"data"`
}

type anthropicModelResponse struct {
	Data []struct {
		Type        string `json:"type"`
		ID          string `json:"id"`
		DisplayName string `json:"display_name"`
	} `json:"data"`
	HasMore *bool `json:"has_more"`
}

func parseModels(kind providerKind, body []byte) ([]ModelOption, error) {
	if len(body) == 0 {
		return nil, providerError(CodeIncompleteResponse, 0)
	}
	if kind == providerKindOpenAI {
		var response openAIModelResponse
		if json.Unmarshal(body, &response) != nil || response.Object != "list" {
			return nil, providerError(CodeMalformedResponse, 0)
		}
		if len(response.Data) == 0 {
			return nil, providerError(CodeIncompleteResponse, 0)
		}
		ids := make([]string, 0, len(response.Data))
		for _, item := range response.Data {
			if !validModelText(item.ID) {
				return nil, providerError(CodeMalformedResponse, 0)
			}
			ids = append(ids, item.ID)
		}
		sort.Strings(ids)
		models := make([]ModelOption, 0, minInt(maxModelOptions, len(ids)))
		seen := make(map[string]struct{}, len(ids))
		for _, id := range ids {
			if _, exists := seen[id]; exists {
				continue
			}
			seen[id] = struct{}{}
			models = append(models, ModelOption{ID: id, Label: id})
			if len(models) == maxModelOptions {
				break
			}
		}
		return models, nil
	}

	var response anthropicModelResponse
	if json.Unmarshal(body, &response) != nil || response.HasMore == nil {
		return nil, providerError(CodeMalformedResponse, 0)
	}
	if len(response.Data) == 0 {
		return nil, providerError(CodeIncompleteResponse, 0)
	}
	candidates := make([]ModelOption, 0, len(response.Data))
	for _, item := range response.Data {
		if item.Type != "model" || !validModelText(item.ID) || !validModelText(item.DisplayName) {
			return nil, providerError(CodeMalformedResponse, 0)
		}
		candidates = append(candidates, ModelOption{ID: item.ID, Label: item.DisplayName})
	}
	sort.Slice(candidates, func(left, right int) bool {
		if candidates[left].ID == candidates[right].ID {
			return candidates[left].Label < candidates[right].Label
		}
		return candidates[left].ID < candidates[right].ID
	})
	models := make([]ModelOption, 0, minInt(maxModelOptions, len(candidates)))
	seen := make(map[string]struct{}, len(candidates))
	for _, candidate := range candidates {
		if _, exists := seen[candidate.ID]; exists {
			continue
		}
		seen[candidate.ID] = struct{}{}
		models = append(models, candidate)
		if len(models) == maxModelOptions {
			break
		}
	}
	return models, nil
}

func minInt(left, right int) int {
	if left < right {
		return left
	}
	return right
}

type openAIRequest struct {
	Model           string `json:"model"`
	Input           string `json:"input"`
	Store           bool   `json:"store"`
	MaxOutputTokens int    `json:"max_output_tokens"`
}

type anthropicRequest struct {
	Model     string             `json:"model"`
	MaxTokens int                `json:"max_tokens"`
	Messages  []anthropicMessage `json:"messages"`
}

type anthropicMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type openAIResponse struct {
	Object           string             `json:"object"`
	Status           string             `json:"status"`
	Error            json.RawMessage    `json:"error"`
	IncompleteDetail json.RawMessage    `json:"incomplete_details"`
	Output           []openAIOutputItem `json:"output"`
	Usage            *openAIUsage       `json:"usage"`
}

type openAIOutputItem struct {
	Type    string              `json:"type"`
	Role    string              `json:"role"`
	Status  string              `json:"status"`
	Content []openAIContentPart `json:"content"`
}

type openAIContentPart struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

type openAIUsage struct {
	InputTokens  int `json:"input_tokens"`
	OutputTokens int `json:"output_tokens"`
}

type anthropicResponse struct {
	Type       string                 `json:"type"`
	Role       string                 `json:"role"`
	Content    []anthropicContentPart `json:"content"`
	StopReason *string                `json:"stop_reason"`
	Usage      *anthropicUsage        `json:"usage"`
}

type anthropicContentPart struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

type anthropicUsage struct {
	InputTokens  int `json:"input_tokens"`
	OutputTokens int `json:"output_tokens"`
}

func parseOpenAIResponse(body []byte) (GenerationResult, error) {
	var response openAIResponse
	if json.Unmarshal(body, &response) != nil {
		return GenerationResult{}, providerError(CodeMalformedResponse, 0)
	}
	if response.Object != "response" {
		return GenerationResult{}, providerError(CodeMalformedResponse, 0)
	}
	if response.Status != "completed" || nonNullJSON(response.Error) || nonNullJSON(response.IncompleteDetail) {
		return GenerationResult{}, providerError(CodeIncompleteResponse, 0)
	}
	if response.Usage == nil || !validUsage(response.Usage.InputTokens) || !validUsage(response.Usage.OutputTokens) {
		return GenerationResult{}, providerError(CodeMalformedResponse, 0)
	}

	texts := make([]string, 0, len(response.Output))
	for _, item := range response.Output {
		switch item.Type {
		case "reasoning":
			continue
		case "message":
			if item.Role != "assistant" || (item.Status != "" && item.Status != "completed") || len(item.Content) == 0 {
				return GenerationResult{}, providerError(CodeMalformedResponse, 0)
			}
			for _, part := range item.Content {
				if part.Type != "output_text" || !validOutputText(part.Text) {
					return GenerationResult{}, providerError(CodeMalformedResponse, 0)
				}
				texts = append(texts, part.Text)
			}
		default:
			return GenerationResult{}, providerError(CodeMalformedResponse, 0)
		}
	}
	return generationResult(texts, response.Usage.InputTokens, response.Usage.OutputTokens)
}

func parseAnthropicResponse(body []byte) (GenerationResult, error) {
	var response anthropicResponse
	if json.Unmarshal(body, &response) != nil {
		return GenerationResult{}, providerError(CodeMalformedResponse, 0)
	}
	if response.Type != "message" || response.Role != "assistant" || response.StopReason == nil ||
		(*response.StopReason != "end_turn" && *response.StopReason != "stop_sequence") {
		return GenerationResult{}, providerError(CodeIncompleteResponse, 0)
	}
	if response.Usage == nil || !validUsage(response.Usage.InputTokens) || !validUsage(response.Usage.OutputTokens) || len(response.Content) == 0 {
		return GenerationResult{}, providerError(CodeMalformedResponse, 0)
	}
	texts := make([]string, 0, len(response.Content))
	for _, part := range response.Content {
		if part.Type != "text" || !validOutputText(part.Text) {
			return GenerationResult{}, providerError(CodeMalformedResponse, 0)
		}
		texts = append(texts, part.Text)
	}
	return generationResult(texts, response.Usage.InputTokens, response.Usage.OutputTokens)
}

func generationResult(texts []string, inputTokens, outputTokens int) (GenerationResult, error) {
	if len(texts) == 0 {
		return GenerationResult{}, providerError(CodeIncompleteResponse, 0)
	}
	text := strings.Join(texts, "\n")
	if !validOutputText(text) {
		return GenerationResult{}, providerError(CodeIncompleteResponse, 0)
	}
	return GenerationResult{Text: text, InputTokens: inputTokens, OutputTokens: outputTokens}, nil
}

func nonNullJSON(value json.RawMessage) bool {
	return len(value) > 0 && string(value) != "null"
}
