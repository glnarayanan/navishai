package runtimecatalog

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

type runtimeTesterFunc func(context.Context, TestRequest) (TestResult, error)

func (function runtimeTesterFunc) TestRuntime(ctx context.Context, request TestRequest) (TestResult, error) {
	return function(ctx, request)
}

func TestRuntimeTestHandlerAuthenticatesAndReturnsOnlyBoundedEvidence(t *testing.T) {
	secret := []byte("runtime-test-handler-secret-at-least-32-bytes")
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	wanted := TestRequest{
		WorkspaceKey:             "c9bb966b-1fe9-4304-bd51-404e4fd9a09c",
		RequestID:                "3d07f334-88ef-4fe4-a640-421e3ba79921",
		DetectionKey:             "a" + string(bytes.Repeat([]byte("b"), 63)),
		ConfigurationFingerprint: string(bytes.Repeat([]byte("c"), 64)),
	}
	executions := 0
	tester := runtimeTesterFunc(func(_ context.Context, request TestRequest) (TestResult, error) {
		executions++
		if request != wanted {
			t.Fatalf("unexpected test request %#v", request)
		}
		return TestResult{
			Status: "passed", EffectiveModel: "fixture-model", ConfigurationFingerprint: request.ConfigurationFingerprint,
			UsageObserved: true, InputUnits: 12, OutputUnits: 3, TestedAt: now,
		}, nil
	})
	handler, err := NewTestHandler(secret, tester, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]string{
		"protocol_version": protocol.Version, "workspace_key": wanted.WorkspaceKey,
		"request_id": wanted.RequestID, "detection_key": wanted.DetectionKey,
		"configuration_fingerprint": wanted.ConfigurationFingerprint,
	})
	request := httptest.NewRequest(http.MethodPost, TestPath, bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	timestamp := strconv.FormatInt(now.Unix(), 10)
	signature, err := protocol.Sign(secret, timestamp, http.MethodPost, TestPath, body)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("X-NavishAI-Timestamp", timestamp)
	request.Header.Set("X-NavishAI-Signature", signature)
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", response.Code, response.Body.String())
	}
	var payload map[string]any
	if json.Unmarshal(response.Body.Bytes(), &payload) != nil || payload["status"] != "passed" ||
		payload["effective_model"] != "fixture-model" || payload["failure_code"] != nil ||
		payload["input_units"] != float64(12) || payload["output_units"] != float64(3) {
		t.Fatalf("unexpected safe test response %#v", payload)
	}
	if _, exposed := payload["output"]; exposed {
		t.Fatal("runtime output was exposed")
	}
	replay := httptest.NewRequest(http.MethodPost, TestPath, bytes.NewReader(body))
	replay.Header = request.Header.Clone()
	replayResponse := httptest.NewRecorder()
	handler.ServeHTTP(replayResponse, replay)
	if replayResponse.Code != http.StatusOK || executions != 1 || replayResponse.Body.String() != response.Body.String() {
		t.Fatalf("exact replay was not idempotent: status=%d executions=%d body=%s", replayResponse.Code, executions, replayResponse.Body.String())
	}
	conflictingBody, _ := json.Marshal(map[string]string{
		"protocol_version": protocol.Version, "workspace_key": wanted.WorkspaceKey,
		"request_id": wanted.RequestID, "detection_key": wanted.DetectionKey,
		"configuration_fingerprint": string(bytes.Repeat([]byte("d"), 64)),
	})
	conflict := httptest.NewRequest(http.MethodPost, TestPath, bytes.NewReader(conflictingBody))
	conflict.Header.Set("Content-Type", "application/json")
	conflict.Header.Set("X-NavishAI-Timestamp", timestamp)
	conflictSignature, _ := protocol.Sign(secret, timestamp, http.MethodPost, TestPath, conflictingBody)
	conflict.Header.Set("X-NavishAI-Signature", conflictSignature)
	conflictResponse := httptest.NewRecorder()
	handler.ServeHTTP(conflictResponse, conflict)
	if conflictResponse.Code != http.StatusConflict || executions != 1 {
		t.Fatalf("conflicting replay was not rejected: status=%d executions=%d", conflictResponse.Code, executions)
	}

	unauthorized := httptest.NewRequest(http.MethodPost, TestPath, bytes.NewReader(body))
	unauthorized.Header.Set("Content-Type", "application/json")
	unauthorizedResponse := httptest.NewRecorder()
	handler.ServeHTTP(unauthorizedResponse, unauthorized)
	if unauthorizedResponse.Code != http.StatusUnauthorized {
		t.Fatalf("expected unauthorized, got %d", unauthorizedResponse.Code)
	}
}

func TestRuntimeTestHandlerMapsTesterAndEvidenceFailures(t *testing.T) {
	secret := []byte("runtime-test-handler-secret-at-least-32-bytes")
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	base := TestRequest{
		WorkspaceKey: "c9bb966b-1fe9-4304-bd51-404e4fd9a09c", RequestID: "3d07f334-88ef-4fe4-a640-421e3ba79921",
		DetectionKey: string(bytes.Repeat([]byte("b"), 64)), ConfigurationFingerprint: string(bytes.Repeat([]byte("c"), 64)),
	}
	cases := []struct {
		name   string
		result TestResult
		err    error
		status int
		code   string
	}{
		{name: "configuration changed", err: ErrTestConfigurationChanged, status: http.StatusConflict, code: "runtime_configuration_changed"},
		{name: "tester unavailable", err: errors.New("down"), status: http.StatusServiceUnavailable, code: "runtime_test_unavailable"},
		{name: "invalid evidence", result: TestResult{Status: "passed"}, status: http.StatusInternalServerError, code: "invalid_runtime_test_result"},
		{name: "bounded failure", result: TestResult{Status: "failed", FailureCode: "provider_rejected", EffectiveModel: "fixture", ConfigurationFingerprint: base.ConfigurationFingerprint, TestedAt: now}, status: http.StatusOK},
	}
	for index, item := range cases {
		t.Run(item.name, func(t *testing.T) {
			requestValue := base
			requestValue.RequestID = fmt.Sprintf("3d07f334-88ef-4fe4-a640-421e3ba7992%d", index+1)
			handler, err := NewTestHandler(secret, runtimeTesterFunc(func(context.Context, TestRequest) (TestResult, error) {
				return item.result, item.err
			}), func() time.Time { return now })
			if err != nil {
				t.Fatal(err)
			}
			body, _ := json.Marshal(map[string]string{
				"protocol_version": protocol.Version, "workspace_key": requestValue.WorkspaceKey, "request_id": requestValue.RequestID,
				"detection_key": requestValue.DetectionKey, "configuration_fingerprint": requestValue.ConfigurationFingerprint,
			})
			request := httptest.NewRequest(http.MethodPost, TestPath, bytes.NewReader(body))
			request.Header.Set("Content-Type", "application/json")
			timestamp := strconv.FormatInt(now.Unix(), 10)
			request.Header.Set("X-NavishAI-Timestamp", timestamp)
			signature, _ := protocol.Sign(secret, timestamp, http.MethodPost, TestPath, body)
			request.Header.Set("X-NavishAI-Signature", signature)
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			if response.Code != item.status {
				t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
			}
			if item.code != "" && !bytes.Contains(response.Body.Bytes(), []byte(item.code)) {
				t.Fatalf("missing code %q: %s", item.code, response.Body.String())
			}
		})
	}
}
