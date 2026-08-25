package protocol

import (
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"strings"
	"time"
)

const (
	Version       = "v1"
	MaxBodyBytes  = 256 * 1024
	MaximumSkew   = 5 * time.Minute
	minimumSecret = 32
)

var (
	uuidPattern       = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	keyPattern        = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}$`)
	rolePattern       = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)
	runtimePattern    = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)
	toolPattern       = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)
	ErrInvalidSecret  = errors.New("runner shared secret must be at least 32 bytes")
	ErrInvalidRequest = errors.New("invalid admission request")
)

type AdmissionRequest struct {
	ProtocolVersion string         `json:"protocol_version"`
	RunID           string         `json:"run_id"`
	IdempotencyKey  string         `json:"idempotency_key"`
	WorkspaceKey    string         `json:"workspace_key"`
	Task            Task           `json:"task"`
	Agent           AgentPolicy    `json:"agent"`
	Routing         RuntimeRouting `json:"routing"`
}

type Task struct {
	TaskKey        string `json:"task_key"`
	Attempt        int    `json:"attempt"`
	Title          string `json:"title"`
	InputContext   string `json:"input_context"`
	ExpectedOutput string `json:"expected_output"`
}

type AgentPolicy struct {
	RoleKey             string   `json:"role_key"`
	PolicyVersion       int      `json:"policy_version"`
	Instructions        string   `json:"instructions"`
	AllowedTools        []string `json:"allowed_tools"`
	RuntimeProfileKey   string   `json:"runtime_profile_key"`
	FallbackProfileKeys []string `json:"fallback_profile_keys"`
	TimeoutSeconds      int      `json:"timeout_seconds"`
	MaxSteps            int      `json:"max_steps"`
	MaxToolCalls        int      `json:"max_tool_calls"`
	ReviewPolicy        string   `json:"review_policy"`
}

type RuntimeRouting struct {
	DetectionKey    string   `json:"detection_key"`
	AdapterKey      string   `json:"adapter_key"`
	ProfileKey      string   `json:"profile_key"`
	SelectionReason string   `json:"selection_reason"`
	SelectionDetail string   `json:"selection_detail"`
	DataClasses     []string `json:"data_classes"`
	MaxInputUnits   int      `json:"max_input_units"`
	MaxOutputUnits  int      `json:"max_output_units"`
}

type AdmissionResponse struct {
	ProtocolVersion string         `json:"protocol_version"`
	RunID           string         `json:"run_id"`
	Status          string         `json:"status"`
	Event           CanonicalEvent `json:"event"`
}

type CanonicalEvent struct {
	ProtocolVersion string         `json:"protocol_version"`
	EventID         string         `json:"event_id"`
	RunID           string         `json:"run_id"`
	Sequence        int            `json:"sequence"`
	EventType       string         `json:"event_type"`
	OccurredAt      time.Time      `json:"occurred_at"`
	Data            map[string]any `json:"data"`
}

type ErrorResponse struct {
	ProtocolVersion string        `json:"protocol_version"`
	Error           ProtocolError `json:"error"`
}

type ProtocolError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func DecodeAdmission(reader io.Reader) (AdmissionRequest, []byte, error) {
	body, err := ReadBody(reader)
	if err != nil {
		return AdmissionRequest{}, nil, ErrInvalidRequest
	}
	request, err := DecodeAdmissionBytes(body)
	return request, body, err
}

func ReadBody(reader io.Reader) ([]byte, error) {
	body, err := io.ReadAll(io.LimitReader(reader, MaxBodyBytes+1))
	if err != nil || len(body) > MaxBodyBytes {
		return nil, ErrInvalidRequest
	}
	return body, nil
}

func DecodeAdmissionBytes(body []byte) (AdmissionRequest, error) {
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	var request AdmissionRequest
	if err := decoder.Decode(&request); err != nil {
		return AdmissionRequest{}, ErrInvalidRequest
	}
	if err := ensureEOF(decoder); err != nil || request.Validate() != nil {
		return AdmissionRequest{}, ErrInvalidRequest
	}
	return request, nil
}

func (request AdmissionRequest) Validate() error {
	if request.ProtocolVersion != Version || !uuidPattern.MatchString(request.RunID) ||
		!keyPattern.MatchString(request.IdempotencyKey) || !uuidPattern.MatchString(request.WorkspaceKey) {
		return ErrInvalidRequest
	}
	if !uuidPattern.MatchString(request.Task.TaskKey) || request.Task.Attempt < 1 || request.Task.Attempt > 100 ||
		!byteLength(request.Task.Title, 1, 200) || !byteLength(request.Task.InputContext, 1, 128*1024) ||
		!byteLength(request.Task.ExpectedOutput, 1, 8000) {
		return ErrInvalidRequest
	}
	agent := request.Agent
	if !rolePattern.MatchString(agent.RoleKey) || agent.PolicyVersion < 1 || !byteLength(agent.Instructions, 1, 8000) ||
		!runtimePattern.MatchString(agent.RuntimeProfileKey) || len(agent.FallbackProfileKeys) > 2 ||
		agent.TimeoutSeconds < 30 || agent.TimeoutSeconds > 900 || agent.MaxSteps < 1 || agent.MaxSteps > 20 ||
		agent.MaxToolCalls < 0 || agent.MaxToolCalls > 50 ||
		(agent.ReviewPolicy != "required" && agent.ReviewPolicy != "on_policy_flag") {
		return ErrInvalidRequest
	}
	if !validDistinctValues(agent.AllowedTools, 8, toolPattern) ||
		!validDistinctValues(agent.FallbackProfileKeys, 2, runtimePattern) ||
		contains(agent.FallbackProfileKeys, agent.RuntimeProfileKey) {
		return ErrInvalidRequest
	}
	routing := request.Routing
	if len(routing.DetectionKey) != 64 || !isLowerHex(routing.DetectionKey) ||
		!runtimePattern.MatchString(routing.AdapterKey) || !runtimePattern.MatchString(routing.ProfileKey) ||
		(routing.SelectionReason != "primary" && routing.SelectionReason != "fallback") ||
		!byteLength(routing.SelectionDetail, 1, 500) ||
		!validDistinctValues(routing.DataClasses, 8, runtimePattern) ||
		routing.MaxInputUnits < 1 || routing.MaxInputUnits > 10_000_000 ||
		routing.MaxOutputUnits < 1 || routing.MaxOutputUnits > 10_000_000 {
		return ErrInvalidRequest
	}
	return nil
}

func isLowerHex(value string) bool {
	for _, character := range value {
		if (character < '0' || character > '9') && (character < 'a' || character > 'f') {
			return false
		}
	}
	return true
}

func ValidateSecret(secret []byte) error {
	if len(secret) < minimumSecret {
		return ErrInvalidSecret
	}
	return nil
}

func Sign(secret []byte, timestamp, method, path string, body []byte) (string, error) {
	if err := ValidateSecret(secret); err != nil {
		return "", err
	}
	digest := sha256.Sum256(body)
	message := strings.Join([]string{timestamp, strings.ToUpper(method), path, hex.EncodeToString(digest[:])}, "\n")
	mac := hmac.New(sha256.New, secret)
	_, _ = mac.Write([]byte(message))
	return hex.EncodeToString(mac.Sum(nil)), nil
}

func Verify(secret []byte, timestamp, method, path string, body []byte, signature string) bool {
	expected, err := Sign(secret, timestamp, method, path, body)
	if err != nil {
		return false
	}
	provided, err := hex.DecodeString(signature)
	if err != nil {
		return false
	}
	expectedBytes, _ := hex.DecodeString(expected)
	return hmac.Equal(provided, expectedBytes)
}

func Digest(body []byte) string {
	digest := sha256.Sum256(body)
	return hex.EncodeToString(digest[:])
}

func NewEventID() (string, error) {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	value[6] = (value[6] & 0x0f) | 0x40
	value[8] = (value[8] & 0x3f) | 0x80
	return strings.ToLower(hex.EncodeToString(value[0:4]) + "-" + hex.EncodeToString(value[4:6]) + "-" +
		hex.EncodeToString(value[6:8]) + "-" + hex.EncodeToString(value[8:10]) + "-" + hex.EncodeToString(value[10:16])), nil
}

func NewCanonicalEvent(runID string, sequence int, eventType string, occurredAt time.Time, data map[string]any) (CanonicalEvent, error) {
	eventID, err := NewEventID()
	if err != nil {
		return CanonicalEvent{}, err
	}
	return CanonicalEvent{
		ProtocolVersion: Version,
		EventID:         eventID,
		RunID:           runID,
		Sequence:        sequence,
		EventType:       eventType,
		OccurredAt:      occurredAt.UTC(),
		Data:            data,
	}, nil
}

func (event CanonicalEvent) Validate() error {
	if event.ProtocolVersion != Version || !uuidPattern.MatchString(event.EventID) || !uuidPattern.MatchString(event.RunID) ||
		event.Sequence < 1 || event.OccurredAt.IsZero() || event.Data == nil {
		return ErrInvalidRequest
	}
	valid := false
	switch event.EventType {
	case "run.admitted":
		valid = exactKeys(event.Data, "workspace_key", "task_key", "attempt") &&
			uuidValue(event.Data["workspace_key"]) && uuidValue(event.Data["task_key"]) && integerValue(event.Data["attempt"], 1)
	case "run.started":
		valid = exactKeys(event.Data, "adapter", "scenario", "attempt") && stringValue(event.Data["adapter"], 64) &&
			stringValue(event.Data["scenario"], 100) && integerValue(event.Data["attempt"], 1)
	case "tool.completed":
		valid = exactKeys(event.Data, "tool", "result") && stringValue(event.Data["tool"], 64) && stringValue(event.Data["result"], 100)
	case "output.produced":
		valid = exactKeys(event.Data, "text") && stringValue(event.Data["text"], 100*1024)
	case "usage.observed":
		valid = exactKeys(event.Data, "input_units", "output_units") && integerValue(event.Data["input_units"], 0) &&
			integerValue(event.Data["output_units"], 0)
	case "run.completed":
		valid = exactKeys(event.Data, "outcome") && event.Data["outcome"] == "completed"
	case "run.failed":
		_, boolean := event.Data["retryable"].(bool)
		valid = exactKeys(event.Data, "code", "retryable") && stringValue(event.Data["code"], 100) && boolean
	case "run.timed_out", "run.canceled":
		valid = exactKeys(event.Data, "reason") && stringValue(event.Data["reason"], 500)
	case "run.policy_denied":
		valid = exactKeys(event.Data, "code", "tool") && stringValue(event.Data["code"], 100) && stringValue(event.Data["tool"], 64)
	}
	if !valid {
		return ErrInvalidRequest
	}
	encoded, err := json.Marshal(event.Data)
	if err != nil || len(encoded) > 128*1024 {
		return ErrInvalidRequest
	}
	return nil
}

func exactKeys(data map[string]any, keys ...string) bool {
	if len(data) != len(keys) {
		return false
	}
	for _, key := range keys {
		if _, exists := data[key]; !exists {
			return false
		}
	}
	return true
}

func uuidValue(value any) bool {
	text, ok := value.(string)
	return ok && uuidPattern.MatchString(text)
}

func stringValue(value any, maximum int) bool {
	text, ok := value.(string)
	return ok && byteLength(text, 1, maximum)
}

func integerValue(value any, minimum int) bool {
	switch number := value.(type) {
	case int:
		return number >= minimum
	case float64:
		return number >= float64(minimum) && number == float64(int64(number))
	default:
		return false
	}
}

func ensureEOF(decoder *json.Decoder) error {
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return ErrInvalidRequest
	}
	return nil
}

func byteLength(value string, minimum, maximum int) bool {
	length := len([]byte(value))
	return strings.TrimSpace(value) != "" && length >= minimum && length <= maximum
}

func validDistinctValues(values []string, maximum int, pattern *regexp.Regexp) bool {
	if len(values) > maximum {
		return false
	}
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		if !pattern.MatchString(value) {
			return false
		}
		if _, exists := seen[value]; exists {
			return false
		}
		seen[value] = struct{}{}
	}
	return true
}

func contains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
