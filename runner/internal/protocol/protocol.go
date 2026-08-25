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
	ProtocolVersion string      `json:"protocol_version"`
	RunID           string      `json:"run_id"`
	IdempotencyKey  string      `json:"idempotency_key"`
	WorkspaceKey    string      `json:"workspace_key"`
	Task            Task        `json:"task"`
	Agent           AgentPolicy `json:"agent"`
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
		!byteLength(request.Task.Title, 1, 200) || !byteLength(request.Task.InputContext, 1, 8000) ||
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
	return nil
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

func ensureEOF(decoder *json.Decoder) error {
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return ErrInvalidRequest
	}
	return nil
}

func byteLength(value string, minimum, maximum int) bool {
	length := len([]byte(strings.TrimSpace(value)))
	return length >= minimum && length <= maximum
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
