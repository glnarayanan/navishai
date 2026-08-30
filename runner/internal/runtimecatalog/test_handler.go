package runtimecatalog

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"mime"
	"net/http"
	"regexp"
	"strconv"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

const TestPath = "/v1/runtimes/test"

var configurationIdentityPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

var ErrTestConfigurationChanged = errors.New("runtime configuration changed")

type TestRequest struct {
	WorkspaceKey             string
	RequestID                string
	DetectionKey             string
	ConfigurationFingerprint string
}

type TestResult struct {
	Status                   string
	FailureCode              string
	EffectiveModel           string
	ConfigurationFingerprint string
	UsageObserved            bool
	InputUnits               int
	OutputUnits              int
	TestedAt                 time.Time
}

type RuntimeTester interface {
	TestRuntime(context.Context, TestRequest) (TestResult, error)
}

type TestHandler struct {
	secret []byte
	tester RuntimeTester
	store  *TestStore
	now    func() time.Time
}

func NewTestHandler(secret []byte, tester RuntimeTester, now func() time.Time) (*TestHandler, error) {
	store, err := OpenTestStore("")
	if err != nil {
		return nil, err
	}
	return NewTestHandlerWithStore(secret, tester, store, now)
}

func NewTestHandlerWithStore(secret []byte, tester RuntimeTester, store *TestStore, now func() time.Time) (*TestHandler, error) {
	if err := protocol.ValidateSecret(secret); err != nil {
		return nil, err
	}
	if tester == nil || store == nil {
		return nil, errors.New("runtime tester is required")
	}
	if now == nil {
		now = time.Now
	}
	return &TestHandler{secret: secret, tester: tester, store: store, now: now}, nil
}

func (handler *TestHandler) ServeHTTP(response http.ResponseWriter, request *http.Request) {
	response.Header().Set("Content-Type", "application/json")
	response.Header().Set("Cache-Control", "no-store")
	if request.ContentLength > protocol.MaxBodyBytes {
		handler.writeError(response, http.StatusRequestEntityTooLarge, "request_too_large", "Request body exceeds the protocol limit.")
		return
	}
	body, err := protocol.ReadBody(request.Body)
	if err != nil {
		handler.writeError(response, http.StatusRequestEntityTooLarge, "request_too_large", "Request body exceeds the protocol limit.")
		return
	}
	timestamp := request.Header.Get("X-NavishAI-Timestamp")
	unixTime, err := strconv.ParseInt(timestamp, 10, 64)
	if err != nil || absoluteDuration(handler.now().Sub(time.Unix(unixTime, 0))) > protocol.MaximumSkew ||
		!protocol.Verify(handler.secret, timestamp, request.Method, request.URL.Path, body, request.Header.Get("X-NavishAI-Signature")) {
		handler.writeError(response, http.StatusUnauthorized, "authentication_failed", "Runner request authentication failed.")
		return
	}
	mediaType, _, err := mime.ParseMediaType(request.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		handler.writeError(response, http.StatusUnsupportedMediaType, "unsupported_media_type", "Runtime test requests must use application/json.")
		return
	}
	var input map[string]any
	if json.Unmarshal(body, &input) != nil || len(input) != 5 || input["protocol_version"] != protocol.Version {
		handler.writeError(response, http.StatusUnprocessableEntity, "invalid_request", "Runtime test request does not match protocol v1.")
		return
	}
	testRequest := TestRequest{
		WorkspaceKey:             stringValue(input["workspace_key"]),
		RequestID:                stringValue(input["request_id"]),
		DetectionKey:             stringValue(input["detection_key"]),
		ConfigurationFingerprint: stringValue(input["configuration_fingerprint"]),
	}
	if !workspaceKeyPattern.MatchString(testRequest.WorkspaceKey) || !workspaceKeyPattern.MatchString(testRequest.RequestID) ||
		!configurationIdentityPattern.MatchString(testRequest.DetectionKey) ||
		!configurationIdentityPattern.MatchString(testRequest.ConfigurationFingerprint) {
		handler.writeError(response, http.StatusUnprocessableEntity, "invalid_request", "Runtime test request does not match protocol v1.")
		return
	}
	digest := sha256.Sum256(body)
	result, _, err := handler.store.Resolve(testRequest, fmt.Sprintf("%x", digest[:]), func() (TestResult, error) {
		return handler.tester.TestRuntime(request.Context(), testRequest)
	})
	if errors.Is(err, ErrTestConflict) {
		handler.writeError(response, http.StatusConflict, "runtime_test_request_conflict", "Runtime test request ID was reused with different input.")
		return
	}
	if errors.Is(err, ErrInvalidTestResult) {
		handler.writeError(response, http.StatusInternalServerError, "invalid_runtime_test_result", "Runtime test returned invalid evidence.")
		return
	}
	if errors.Is(err, ErrTestConfigurationChanged) {
		handler.writeError(response, http.StatusConflict, "runtime_configuration_changed", "Runtime configuration changed. Detect it again before testing.")
		return
	}
	if err != nil {
		handler.writeError(response, http.StatusServiceUnavailable, "runtime_test_unavailable", "Runtime test could not be completed.")
		return
	}
	var failureCode any
	if result.FailureCode != "" {
		failureCode = result.FailureCode
	}
	_ = json.NewEncoder(response).Encode(map[string]any{
		"protocol_version":          protocol.Version,
		"workspace_key":             testRequest.WorkspaceKey,
		"request_id":                testRequest.RequestID,
		"detection_key":             testRequest.DetectionKey,
		"configuration_fingerprint": result.ConfigurationFingerprint,
		"effective_model":           result.EffectiveModel,
		"status":                    result.Status,
		"failure_code":              failureCode,
		"usage_observed":            result.UsageObserved,
		"input_units":               result.InputUnits,
		"output_units":              result.OutputUnits,
		"tested_at":                 result.TestedAt.UTC().Format(time.RFC3339),
	})
}

func validTestResult(result TestResult, wantedFingerprint string) bool {
	if result.ConfigurationFingerprint != wantedFingerprint || !validConfigurationIdentity(result.EffectiveModel, result.ConfigurationFingerprint) ||
		result.InputUnits < 0 || result.OutputUnits < 0 || result.TestedAt.IsZero() {
		return false
	}
	if result.Status == "passed" {
		return result.FailureCode == ""
	}
	return result.Status == "failed" && regexp.MustCompile(`^[a-z0-9_]{1,64}$`).MatchString(result.FailureCode)
}

func (handler *TestHandler) writeError(response http.ResponseWriter, status int, code, message string) {
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(protocol.ErrorResponse{
		ProtocolVersion: protocol.Version,
		Error:           protocol.ProtocolError{Code: code, Message: message},
	})
}
