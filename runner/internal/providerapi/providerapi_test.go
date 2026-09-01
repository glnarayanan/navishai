package providerapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

type fakeDoer struct {
	requests []*http.Request
	fn       func(*http.Request) (*http.Response, error)
}

func (doer *fakeDoer) Do(request *http.Request) (*http.Response, error) {
	doer.requests = append(doer.requests, request)
	return doer.fn(request)
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return fn(request)
}

func jsonResponse(status int, body string) *http.Response {
	return &http.Response{
		StatusCode:    status,
		Header:        http.Header{"Content-Type": []string{"application/json; charset=utf-8"}},
		Body:          io.NopCloser(strings.NewReader(body)),
		ContentLength: int64(len(body)),
	}
}

func errorCode(t *testing.T, err error) ErrorCode {
	t.Helper()
	if err == nil {
		t.Fatal("expected provider API error")
	}
	var providerErr *Error
	if !errors.As(err, &providerErr) {
		t.Fatalf("expected sanitized provider API error, got %T: %v", err, err)
	}
	return providerErr.Code
}

func requireErrorCode(t *testing.T, err error, expected ErrorCode) {
	t.Helper()
	if got := errorCode(t, err); got != expected {
		t.Fatalf("unexpected provider API error code: got %q, want %q", got, expected)
	}
}

func TestSupportsReportsRegisteredProviderAPIContracts(t *testing.T) {
	for _, test := range []struct {
		adapterKey string
		supported  bool
	}{
		{adapterKey: "codex_subscription", supported: true},
		{adapterKey: "claude_subscription", supported: true},
		{adapterKey: "cursor_subscription"},
		{adapterKey: "unknown"},
	} {
		if got := Supports(test.adapterKey); got != test.supported {
			t.Fatalf("Supports(%q) = %t, want %t", test.adapterKey, got, test.supported)
		}
	}
}

func TestNewUsesCallerBoundedHTTPClient(t *testing.T) {
	client := New()
	httpClient, ok := client.doer.(*http.Client)
	if !ok {
		t.Fatalf("default doer type = %T, want *http.Client", client.doer)
	}
	if httpClient.Timeout != 0 {
		t.Fatalf("client timeout = %s, want caller-owned context deadline", httpClient.Timeout)
	}
	if httpClient.CheckRedirect == nil {
		t.Fatal("default client must reject redirects")
	}
	transport, ok := httpClient.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("default transport type = %T, want *http.Transport", httpClient.Transport)
	}
	if transport.Proxy != nil {
		t.Fatal("default provider transport must not use ambient proxies")
	}
}

func TestDiscoverModelsUsesDedicatedDeadline(t *testing.T) {
	var requestDeadline time.Time
	doer := &fakeDoer{fn: func(request *http.Request) (*http.Response, error) {
		requestDeadline, _ = request.Context().Deadline()
		return jsonResponse(http.StatusOK, `{"object":"list","data":[{"id":"gpt-future"}]}`), nil
	}}
	started := time.Now()
	if _, err := newWithDoer(doer).DiscoverModels(context.Background(), "codex_subscription", "sk-openai-test"); err != nil {
		t.Fatalf("DiscoverModels returned error: %v", err)
	}
	remaining := time.Until(requestDeadline)
	if requestDeadline.IsZero() || remaining <= 0 || requestDeadline.Before(started.Add(modelDiscoveryTimeout-time.Second)) ||
		requestDeadline.After(started.Add(modelDiscoveryTimeout+time.Second)) {
		t.Fatalf("model discovery deadline = %s, want approximately %s from call start", requestDeadline, modelDiscoveryTimeout)
	}
}

func TestDiscoverModelsOpenAIUsesFixedEndpointAndAuth(t *testing.T) {
	doer := &fakeDoer{fn: func(request *http.Request) (*http.Response, error) {
		return jsonResponse(http.StatusOK, `{"object":"list","data":[{"id":"o4-mini"},{"id":"gpt-99-preview"}]}`), nil
	}}
	client := newWithDoer(doer)

	models, err := client.DiscoverModels(context.Background(), "codex_subscription", "sk-openai-test")
	if err != nil {
		t.Fatalf("DiscoverModels returned error: %v", err)
	}
	want := []ModelOption{
		{ID: "gpt-99-preview", Label: "gpt-99-preview"},
		{ID: "o4-mini", Label: "o4-mini"},
	}
	if !reflect.DeepEqual(models, want) {
		t.Fatalf("models = %#v, want %#v", models, want)
	}
	if len(doer.requests) != 1 {
		t.Fatalf("request count = %d, want 1", len(doer.requests))
	}
	request := doer.requests[0]
	if request.Method != http.MethodGet || request.URL.String() != "https://api.openai.com/v1/models" {
		t.Fatalf("request = %s %s, want GET fixed OpenAI models endpoint", request.Method, request.URL)
	}
	if request.Header.Get("Accept") != "application/json" {
		t.Fatalf("Accept = %q, want application/json", request.Header.Get("Accept"))
	}
	if request.Header.Get("Authorization") != "Bearer sk-openai-test" {
		t.Fatalf("Authorization header = %q, want exact bearer credential", request.Header.Get("Authorization"))
	}
	if request.Header.Get("Content-Type") != "" {
		t.Fatalf("GET Content-Type = %q, want omitted", request.Header.Get("Content-Type"))
	}
}

func TestDiscoverModelsAnthropicUsesFixedEndpointAndHeaders(t *testing.T) {
	doer := &fakeDoer{fn: func(request *http.Request) (*http.Response, error) {
		return jsonResponse(http.StatusOK, `{"data":[{"type":"model","id":"claude-future-1","display_name":"Claude Future 1"}],"has_more":false}`), nil
	}}
	client := newWithDoer(doer)

	models, err := client.DiscoverModels(context.Background(), "claude_subscription", "anthropic-test-key")
	if err != nil {
		t.Fatalf("DiscoverModels returned error: %v", err)
	}
	want := []ModelOption{{ID: "claude-future-1", Label: "Claude Future 1"}}
	if !reflect.DeepEqual(models, want) {
		t.Fatalf("models = %#v, want %#v", models, want)
	}
	request := doer.requests[0]
	if request.Method != http.MethodGet || request.URL.String() != "https://api.anthropic.com/v1/models?limit=100" {
		t.Fatalf("request = %s %s, want GET fixed Anthropic models endpoint", request.Method, request.URL)
	}
	if request.Header.Get("Accept") != "application/json" {
		t.Fatalf("Accept = %q, want application/json", request.Header.Get("Accept"))
	}
	if request.Header.Get("x-api-key") != "anthropic-test-key" {
		t.Fatalf("x-api-key header = %q, want exact credential", request.Header.Get("x-api-key"))
	}
	if request.Header.Get("anthropic-version") != anthropicVersion {
		t.Fatalf("anthropic-version = %q, want %q", request.Header.Get("anthropic-version"), anthropicVersion)
	}
}

func TestGenerateOpenAIDisablesToolsAndExtractsCompletedResponse(t *testing.T) {
	doer := &fakeDoer{fn: func(request *http.Request) (*http.Response, error) {
		return jsonResponse(http.StatusOK, `{
			"id":"resp_1","object":"response","status":"completed",
			"output":[
				{"type":"reasoning","id":"rs_1","summary":[]},
				{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"final answer"}]}
			],
			"usage":{"input_tokens":7,"output_tokens":4}
		}`), nil
	}}
	client := newWithDoer(doer)

	result, err := client.Generate(context.Background(), "codex_subscription", "sk-openai-test", "gpt-future", "Explain this.", 512)
	if err != nil {
		t.Fatalf("Generate returned error: %v", err)
	}
	if result != (GenerationResult{Text: "final answer", InputTokens: 7, OutputTokens: 4}) {
		t.Fatalf("result = %#v, want completed final text and usage", result)
	}
	request := doer.requests[0]
	if request.Method != http.MethodPost || request.URL.String() != "https://api.openai.com/v1/responses" {
		t.Fatalf("request = %s %s, want POST fixed OpenAI Responses endpoint", request.Method, request.URL)
	}
	if request.Header.Get("Content-Type") != "application/json" {
		t.Fatalf("Content-Type = %q, want application/json", request.Header.Get("Content-Type"))
	}
	var payload map[string]any
	if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
		t.Fatalf("decode request body: %v", err)
	}
	if payload["model"] != "gpt-future" || payload["input"] != "Explain this." || payload["store"] != false || payload["max_output_tokens"] != float64(512) {
		t.Fatalf("unexpected OpenAI request payload: %#v", payload)
	}
	if _, exists := payload["tools"]; exists {
		t.Fatalf("OpenAI request must omit tools: %#v", payload)
	}
}

func TestGenerateAnthropicDisablesToolsAndExtractsCompletedResponse(t *testing.T) {
	doer := &fakeDoer{fn: func(request *http.Request) (*http.Response, error) {
		return jsonResponse(http.StatusOK, `{
			"id":"msg_1","type":"message","role":"assistant","model":"claude-future-1",
			"content":[{"type":"text","text":"final answer"}],
			"stop_reason":"end_turn","usage":{"input_tokens":9,"output_tokens":5}
		}`), nil
	}}
	client := newWithDoer(doer)

	result, err := client.Generate(context.Background(), "claude_subscription", "anthropic-test-key", "claude-future-1", "Explain this.", 256)
	if err != nil {
		t.Fatalf("Generate returned error: %v", err)
	}
	if result != (GenerationResult{Text: "final answer", InputTokens: 9, OutputTokens: 5}) {
		t.Fatalf("result = %#v, want completed final text and usage", result)
	}
	request := doer.requests[0]
	if request.Method != http.MethodPost || request.URL.String() != "https://api.anthropic.com/v1/messages" {
		t.Fatalf("request = %s %s, want POST fixed Anthropic Messages endpoint", request.Method, request.URL)
	}
	var payload map[string]any
	if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
		t.Fatalf("decode request body: %v", err)
	}
	if payload["model"] != "claude-future-1" || payload["max_tokens"] != float64(256) {
		t.Fatalf("unexpected Anthropic request payload: %#v", payload)
	}
	messages, ok := payload["messages"].([]any)
	if !ok || len(messages) != 1 || messages[0].(map[string]any)["role"] != "user" || messages[0].(map[string]any)["content"] != "Explain this." {
		t.Fatalf("unexpected Anthropic messages payload: %#v", payload["messages"])
	}
	if _, exists := payload["tools"]; exists {
		t.Fatalf("Anthropic request must omit tools: %#v", payload)
	}
}

func TestParseModelsDeduplicatesSortsAndBoundsAccessibleModels(t *testing.T) {
	openAIData := make([]map[string]string, 0, 103)
	for index := 102; index >= 0; index-- {
		openAIData = append(openAIData, map[string]string{"id": fmtModelID(index)})
	}
	openAIData = append(openAIData, map[string]string{"id": fmtModelID(1)})
	openAIBody := mustJSON(t, map[string]any{"object": "list", "data": openAIData})
	openAIModels, err := parseModels(providerKindOpenAI, openAIBody)
	if err != nil {
		t.Fatalf("OpenAI catalog with more than 100 accessible models failed: %v", err)
	}
	if len(openAIModels) != maxModelOptions || openAIModels[0].ID != "future-000" || openAIModels[len(openAIModels)-1].ID != "future-099" {
		t.Fatalf("OpenAI models were not sorted and capped deterministically: first=%#v last=%#v count=%d", openAIModels[0], openAIModels[len(openAIModels)-1], len(openAIModels))
	}

	anthropicData := make([]map[string]string, 0, 102)
	for index := 101; index >= 0; index-- {
		anthropicData = append(anthropicData, map[string]string{
			"type": "model", "id": fmtModelID(index), "display_name": "Label " + fmtModelID(index),
		})
	}
	// The deterministic label tie-breaker keeps the first duplicate stable.
	anthropicData = append(anthropicData,
		map[string]string{"type": "model", "id": "future-001", "display_name": "Z label"},
		map[string]string{"type": "model", "id": "future-001", "display_name": "A label"},
	)
	anthropicBody := mustJSON(t, map[string]any{"data": anthropicData, "has_more": true})
	anthropicModels, err := parseModels(providerKindAnthropic, anthropicBody)
	if err != nil {
		t.Fatalf("Anthropic first page with has_more=true failed: %v", err)
	}
	if len(anthropicModels) != maxModelOptions || anthropicModels[0].ID != "future-000" || anthropicModels[len(anthropicModels)-1].ID != "future-099" {
		t.Fatalf("Anthropic models were not sorted and capped deterministically: first=%#v last=%#v count=%d", anthropicModels[0], anthropicModels[len(anthropicModels)-1], len(anthropicModels))
	}
	if anthropicModels[1].Label != "A label" {
		t.Fatalf("duplicate Anthropic model did not use deterministic label: %#v", anthropicModels[1])
	}
}

func TestParseModelsRejectsMalformedOrIncompleteCatalogs(t *testing.T) {
	tests := []struct {
		name string
		kind providerKind
		body []byte
		code ErrorCode
	}{
		{name: "empty", kind: providerKindOpenAI, body: nil, code: CodeIncompleteResponse},
		{name: "invalid json", kind: providerKindOpenAI, body: []byte("{"), code: CodeMalformedResponse},
		{name: "wrong object", kind: providerKindOpenAI, body: []byte(`{"object":"response","data":[]}`), code: CodeMalformedResponse},
		{name: "openai empty", kind: providerKindOpenAI, body: []byte(`{"object":"list","data":[]}`), code: CodeIncompleteResponse},
		{name: "openai control", kind: providerKindOpenAI, body: []byte(`{"object":"list","data":[{"id":"future-\u0001"}]}`), code: CodeMalformedResponse},
		{name: "anthropic missing page marker", kind: providerKindAnthropic, body: []byte(`{"data":[]}`), code: CodeMalformedResponse},
		{name: "anthropic empty", kind: providerKindAnthropic, body: []byte(`{"data":[],"has_more":false}`), code: CodeIncompleteResponse},
		{name: "anthropic wrong type", kind: providerKindAnthropic, body: []byte(`{"data":[{"type":"not-model","id":"future-1","display_name":"Future"}],"has_more":false}`), code: CodeMalformedResponse},
		{name: "anthropic trimmed id", kind: providerKindAnthropic, body: []byte(`{"data":[{"type":"model","id":" future-1","display_name":"Future"}],"has_more":false}`), code: CodeMalformedResponse},
		{name: "anthropic control label", kind: providerKindAnthropic, body: []byte("{\"data\":[{\"type\":\"model\",\"id\":\"future-1\",\"display_name\":\"Future\\u000a\"}],\"has_more\":false}"), code: CodeMalformedResponse},
		{name: "invalid utf8", kind: providerKindOpenAI, body: []byte{'{', '}', 0xff}, code: CodeMalformedResponse},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := parseModels(test.kind, test.body)
			requireErrorCode(t, err, test.code)
		})
	}
}

func fmtModelID(index int) string {
	return fmt.Sprintf("future-%03d", index)
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	body, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("marshal test JSON: %v", err)
	}
	return body
}

func TestGenerateRejectsInvalidInputBeforeCallingProvider(t *testing.T) {
	doer := &fakeDoer{fn: func(*http.Request) (*http.Response, error) {
		return nil, errors.New("fake provider must not be called")
	}}
	client := newWithDoer(doer)
	tests := []struct {
		name        string
		adapterKey  string
		apiKey      string
		model       string
		prompt      string
		outputToken int
		ctx         context.Context
		code        ErrorCode
	}{
		{name: "unsupported adapter", adapterKey: "grok_subscription", apiKey: "sk-key", model: "future", prompt: "Prompt", outputToken: 10, code: CodeUnsupportedProvider},
		{name: "empty api key", adapterKey: "codex_subscription", model: "future", prompt: "Prompt", outputToken: 10, code: CodeInvalidInput},
		{name: "control api key", adapterKey: "codex_subscription", apiKey: "sk-key\n", model: "future", prompt: "Prompt", outputToken: 10, code: CodeInvalidInput},
		{name: "trimmed model", adapterKey: "codex_subscription", apiKey: "sk-key", model: " future", prompt: "Prompt", outputToken: 10, code: CodeInvalidInput},
		{name: "oversized model", adapterKey: "codex_subscription", apiKey: "sk-key", model: strings.Repeat("m", maxModelBytes+1), prompt: "Prompt", outputToken: 10, code: CodeInvalidInput},
		{name: "blank prompt", adapterKey: "codex_subscription", apiKey: "sk-key", model: "future", prompt: " \t", outputToken: 10, code: CodeInvalidInput},
		{name: "control prompt", adapterKey: "codex_subscription", apiKey: "sk-key", model: "future", prompt: "Prompt\x00", outputToken: 10, code: CodeInvalidInput},
		{name: "oversized prompt", adapterKey: "codex_subscription", apiKey: "sk-key", model: "future", prompt: strings.Repeat("p", maxPromptBytes+1), outputToken: 10, code: CodeInvalidInput},
		{name: "zero output tokens", adapterKey: "codex_subscription", apiKey: "sk-key", model: "future", prompt: "Prompt", outputToken: 0, code: CodeInvalidInput},
		{name: "oversized output tokens", adapterKey: "codex_subscription", apiKey: "sk-key", model: "future", prompt: "Prompt", outputToken: maxOutputTokens + 1, code: CodeInvalidInput},
		{name: "nil context", adapterKey: "codex_subscription", apiKey: "sk-key", model: "future", prompt: "Prompt", outputToken: 10, ctx: nil, code: CodeInvalidInput},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ctx := test.ctx
			if ctx == nil && test.name != "nil context" {
				ctx = context.Background()
			}
			_, err := client.Generate(ctx, test.adapterKey, test.apiKey, test.model, test.prompt, test.outputToken)
			requireErrorCode(t, err, test.code)
		})
	}
	if len(doer.requests) != 0 {
		t.Fatalf("provider was called for invalid input: %d requests", len(doer.requests))
	}
}

func TestHTTPFailuresAreTypedAndSecretSafe(t *testing.T) {
	const secret = "sk-provider-secret-value"
	statuses := []struct {
		name   string
		code   ErrorCode
		status int
	}{
		{name: "unauthorized", code: CodeAuthentication, status: http.StatusUnauthorized},
		{name: "forbidden", code: CodeAuthentication, status: http.StatusForbidden},
		{name: "rate limited", code: CodeUnavailable, status: http.StatusTooManyRequests},
		{name: "server failure", code: CodeUnavailable, status: http.StatusBadGateway},
		{name: "other failure", code: CodeHTTPStatus, status: http.StatusTeapot},
	}
	for _, test := range statuses {
		t.Run(test.name, func(t *testing.T) {
			doer := &fakeDoer{fn: func(*http.Request) (*http.Response, error) {
				return jsonResponse(test.status, `{"error":"`+secret+`"}`), nil
			}}
			_, err := newWithDoer(doer).DiscoverModels(context.Background(), "codex_subscription", secret)
			requireErrorCode(t, err, test.code)
			if strings.Contains(err.Error(), secret) || strings.Contains(err.Error(), "provider failure") {
				t.Fatalf("sanitized error leaked provider data: %v", err)
			}
		})
	}
}

func TestTransportFailuresAndRedirectsAreTyped(t *testing.T) {
	timeout := fakeTimeoutError{}
	tests := []struct {
		name string
		err  error
		code ErrorCode
	}{
		{name: "deadline", err: context.DeadlineExceeded, code: CodeTimeout},
		{name: "canceled", err: context.Canceled, code: CodeCanceled},
		{name: "network timeout", err: timeout, code: CodeTimeout},
		{name: "transport", err: errors.New("transport leaked secret"), code: CodeTransport},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			doer := &fakeDoer{fn: func(*http.Request) (*http.Response, error) { return nil, test.err }}
			_, err := newWithDoer(doer).DiscoverModels(context.Background(), "codex_subscription", "sk-key")
			requireErrorCode(t, err, test.code)
			if strings.Contains(err.Error(), "transport leaked secret") {
				t.Fatalf("transport error was not sanitized: %v", err)
			}
		})
	}

	calls := 0
	transport := roundTripFunc(func(request *http.Request) (*http.Response, error) {
		calls++
		return jsonResponse(http.StatusFound, `{"location":"https://unexpected.example"}`), nil
	})
	_, err := newWithTransport(transport).DiscoverModels(context.Background(), "codex_subscription", "sk-key")
	requireErrorCode(t, err, CodeRedirectRejected)
	if calls != 1 {
		t.Fatalf("redirect transport calls = %d, want one rejected request", calls)
	}
}

type fakeTimeoutError struct{}

func (fakeTimeoutError) Error() string   { return "provider timeout" }
func (fakeTimeoutError) Timeout() bool   { return true }
func (fakeTimeoutError) Temporary() bool { return true }

func TestResponseBoundsAndContentTypeAreEnforced(t *testing.T) {
	tests := []struct {
		name     string
		response *http.Response
		code     ErrorCode
	}{
		{name: "missing body", response: &http.Response{StatusCode: http.StatusOK, Header: http.Header{}}, code: CodeResponseTooLarge},
		{name: "missing content type", response: responseWithBody(http.StatusOK, "{}", "", int64(len("{}"))), code: CodeMalformedResponse},
		{name: "wrong content type", response: responseWithBody(http.StatusOK, "{}", "text/html", int64(len("{}"))), code: CodeMalformedResponse},
		{name: "declared oversized", response: responseWithBody(http.StatusOK, "{}", "application/json", maxResponseBodyBytes+1), code: CodeResponseTooLarge},
		{name: "invalid utf8", response: responseWithBytes(http.StatusOK, []byte{'{', 0xff}, "application/json"), code: CodeMalformedResponse},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			doer := &fakeDoer{fn: func(*http.Request) (*http.Response, error) { return test.response, nil }}
			_, err := newWithDoer(doer).DiscoverModels(context.Background(), "codex_subscription", "sk-key")
			requireErrorCode(t, err, test.code)
		})
	}

	oversized := strings.Repeat("x", maxResponseBodyBytes+1)
	doer := &fakeDoer{fn: func(*http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, oversized, "application/json", -1), nil
	}}
	_, err := newWithDoer(doer).DiscoverModels(context.Background(), "codex_subscription", "sk-key")
	requireErrorCode(t, err, CodeResponseTooLarge)
}

func responseWithBody(status int, body, contentType string, contentLength int64) *http.Response {
	return &http.Response{
		StatusCode:    status,
		Header:        http.Header{"Content-Type": []string{contentType}},
		Body:          io.NopCloser(strings.NewReader(body)),
		ContentLength: contentLength,
	}
}

func responseWithBytes(status int, body []byte, contentType string) *http.Response {
	return &http.Response{
		StatusCode:    status,
		Header:        http.Header{"Content-Type": []string{contentType}},
		Body:          io.NopCloser(bytes.NewReader(body)),
		ContentLength: int64(len(body)),
	}
}

func TestResponseBodiesCloseOnEveryReturnedResponse(t *testing.T) {
	statuses := []int{http.StatusFound, http.StatusUnauthorized, http.StatusBadGateway, http.StatusOK}
	for _, status := range statuses {
		t.Run(fmt.Sprintf("status_%d", status), func(t *testing.T) {
			body := &trackingBody{reader: strings.NewReader(`{"object":"list","data":[]}`)}
			doer := &fakeDoer{fn: func(*http.Request) (*http.Response, error) {
				return &http.Response{
					StatusCode: status,
					Header:     http.Header{"Content-Type": []string{"application/json"}},
					Body:       body,
				}, nil
			}}
			_, _ = newWithDoer(doer).DiscoverModels(context.Background(), "codex_subscription", "sk-key")
			if !body.closed {
				t.Fatalf("response body for status %d was not closed", status)
			}
		})
	}

	body := &trackingBody{reader: strings.NewReader("provider error")}
	doer := &fakeDoer{fn: func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusBadGateway, Body: body}, errors.New("transport error")
	}}
	_, _ = newWithDoer(doer).DiscoverModels(context.Background(), "codex_subscription", "sk-key")
	if !body.closed {
		t.Fatal("response body returned with a transport error was not closed")
	}
}

type trackingBody struct {
	reader *strings.Reader
	closed bool
}

func (body *trackingBody) Read(value []byte) (int, error) { return body.reader.Read(value) }

func (body *trackingBody) Close() error {
	body.closed = true
	return nil
}

func TestGenerateRejectsMalformedAndIncompleteProviderResponses(t *testing.T) {
	tests := []struct {
		name       string
		adapterKey string
		body       string
		code       ErrorCode
	}{
		{
			name:       "openai wrong object",
			adapterKey: "codex_subscription",
			body:       `{"object":"not-response","status":"completed","output":[],"usage":{"input_tokens":1,"output_tokens":1}}`,
			code:       CodeMalformedResponse,
		},
		{
			name:       "openai incomplete status",
			adapterKey: "codex_subscription",
			body:       `{"object":"response","status":"incomplete","output":[],"usage":{"input_tokens":1,"output_tokens":1}}`,
			code:       CodeIncompleteResponse,
		},
		{
			name:       "openai only reasoning",
			adapterKey: "codex_subscription",
			body:       `{"object":"response","status":"completed","output":[{"type":"reasoning"}],"usage":{"input_tokens":1,"output_tokens":1}}`,
			code:       CodeIncompleteResponse,
		},
		{
			name:       "openai unsupported output",
			adapterKey: "codex_subscription",
			body:       `{"object":"response","status":"completed","output":[{"type":"function_call"}],"usage":{"input_tokens":1,"output_tokens":1}}`,
			code:       CodeMalformedResponse,
		},
		{
			name:       "openai control output",
			adapterKey: "codex_subscription",
			body:       `{"object":"response","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"bad\u0001"}]}],"usage":{"input_tokens":1,"output_tokens":1}}`,
			code:       CodeMalformedResponse,
		},
		{
			name:       "openai provider error",
			adapterKey: "codex_subscription",
			body:       `{"object":"response","status":"completed","error":{"message":"secret"},"output":[],"usage":{"input_tokens":1,"output_tokens":1}}`,
			code:       CodeIncompleteResponse,
		},
		{
			name:       "anthropic incomplete stop reason",
			adapterKey: "claude_subscription",
			body:       `{"type":"message","role":"assistant","content":[{"type":"text","text":"partial"}],"stop_reason":"max_tokens","usage":{"input_tokens":1,"output_tokens":1}}`,
			code:       CodeIncompleteResponse,
		},
		{
			name:       "anthropic unsupported content",
			adapterKey: "claude_subscription",
			body:       `{"type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}`,
			code:       CodeMalformedResponse,
		},
		{
			name:       "anthropic invalid usage",
			adapterKey: "claude_subscription",
			body:       `{"type":"message","role":"assistant","content":[{"type":"text","text":"answer"}],"stop_reason":"end_turn","usage":{"input_tokens":-1,"output_tokens":1}}`,
			code:       CodeMalformedResponse,
		},
		{
			name:       "invalid json",
			adapterKey: "claude_subscription",
			body:       "{",
			code:       CodeMalformedResponse,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			doer := &fakeDoer{fn: func(*http.Request) (*http.Response, error) {
				return jsonResponse(http.StatusOK, test.body), nil
			}}
			_, err := newWithDoer(doer).Generate(context.Background(), test.adapterKey, "sk-key", "future-model", "Prompt", 32)
			requireErrorCode(t, err, test.code)
		})
	}
}
