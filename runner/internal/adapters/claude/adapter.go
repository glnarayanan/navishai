package claude

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

const (
	AdapterKey  = "claude_subscription"
	minVersion  = "2.1.169"
	maxVersion  = "2.1.299"
	maxLineSize = 128 * 1024
)

var (
	sessionIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	versionPattern   = regexp.MustCompile(`\b2\.1\.(\d+)\b`)
)

type Invocation struct {
	Admission        protocol.AdmissionRequest
	Executable       string
	WorkingDir       string
	ClaudeConfigDir  string
	Model            string
	Prompt           string
	EgressProfileKey string
}

type Result struct {
	Status      string
	Output      string
	SessionID   string
	InputUnits  int
	OutputUnits int
	FailureCode string
}

type Adapter struct {
	now func() time.Time
}

func Definition() runtimecatalog.Definition {
	return runtimecatalog.Definition{
		AdapterKey: AdapterKey, ProtocolVersion: protocol.Version, ExecutableNames: []string{"claude"},
		VersionArguments: []string{"--version"}, AccountArguments: []string{"auth", "status"},
		AccountValidator: validSubscriptionStatus, AccountEnvironment: []string{"CLAUDE_CONFIG_DIR"},
		AccountMetadata: map[string]string{"authentication": "claude_subscription"},
		Capabilities:    []string{"structured_output", "tool_calling"},
		MinimumVersion:  minVersion, MaximumVersion: maxVersion,
	}
}

func validSubscriptionStatus(output string) bool {
	var status struct {
		LoggedIn         bool   `json:"loggedIn"`
		AuthMethod       string `json:"authMethod"`
		APIProvider      string `json:"apiProvider"`
		SubscriptionType string `json:"subscriptionType"`
	}
	if json.Unmarshal([]byte(output), &status) != nil || !status.LoggedIn || status.AuthMethod != "oauth_token" || status.APIProvider != "firstParty" {
		return false
	}
	switch strings.ToLower(status.SubscriptionType) {
	case "pro", "max", "team", "enterprise":
		return true
	default:
		return false
	}
}

func New(now func() time.Time) *Adapter {
	if now == nil {
		now = time.Now
	}
	return &Adapter{now: now}
}

func (adapter *Adapter) Execute(ctx context.Context, invocation Invocation, runner adapters.ProcessRunner, emit func(protocol.CanonicalEvent) error) (Result, error) {
	if runner == nil || emit == nil || strings.TrimSpace(invocation.Prompt) == "" || invocation.ClaudeConfigDir == "" ||
		invocation.Model == "" || invocation.EgressProfileKey == "" {
		return Result{}, errors.New("invalid Claude invocation")
	}
	sequence := 2
	emitEvent := func(eventType string, data map[string]any) error {
		event, err := protocol.NewCanonicalEvent(invocation.Admission.RunID, sequence, eventType, adapter.now(), data)
		if err != nil {
			return err
		}
		if err := emit(event); err != nil {
			return fmt.Errorf("emit %s: %w", eventType, err)
		}
		sequence++
		return nil
	}
	if err := emitEvent("run.started", map[string]any{
		"adapter": AdapterKey, "scenario": "subscription", "attempt": invocation.Admission.Task.Attempt,
	}); err != nil {
		return Result{}, err
	}
	process, processErr := runner.Run(ctx, supervisor.Request{
		Executable: invocation.Executable, Arguments: arguments(invocation), WorkingDir: invocation.WorkingDir,
		Input: []byte(invocation.Prompt), Credentials: map[string]string{"CLAUDE_CONFIG_DIR": invocation.ClaudeConfigDir},
		EgressProfileKey: invocation.EgressProfileKey,
	})
	if process.TimedOut {
		return Result{Status: "timed_out", FailureCode: "claude_timed_out"}, emitEvent("run.timed_out", map[string]any{"reason": "Claude exceeded the run deadline."})
	}
	if process.Canceled {
		return Result{Status: "canceled", FailureCode: "claude_canceled"}, emitEvent("run.canceled", map[string]any{"reason": "Claude was canceled."})
	}
	if processErr != nil {
		return Result{Status: "failed", FailureCode: "claude_process_failed"}, emitEvent("run.failed", map[string]any{"code": "claude_process_failed", "retryable": false})
	}
	normalized, parseErr := parseJSONL(process.StandardOutput)
	if parseErr != nil || process.ExitCode != 0 || normalized.FailureCode != "" {
		code := normalized.FailureCode
		if code == "" {
			code = "claude_failed"
		}
		if parseErr != nil {
			code = "claude_malformed_output"
		}
		return Result{Status: "failed", FailureCode: code}, emitEvent("run.failed", map[string]any{"code": code, "retryable": false})
	}
	if !adapters.WithinUnitBudget(invocation.Admission, normalized.InputUnits, normalized.OutputUnits) {
		return Result{Status: "failed", FailureCode: "runtime_unit_budget_exceeded"}, emitEvent("run.failed", map[string]any{"code": "runtime_unit_budget_exceeded", "retryable": false})
	}
	if err := emitEvent("output.produced", map[string]any{"text": normalized.Output}); err != nil {
		return Result{}, err
	}
	if err := emitEvent("usage.observed", map[string]any{"input_units": normalized.InputUnits, "output_units": normalized.OutputUnits}); err != nil {
		return Result{}, err
	}
	if err := emitEvent("run.completed", map[string]any{"outcome": "completed"}); err != nil {
		return Result{}, err
	}
	return Result{
		Status: "completed", Output: normalized.Output, SessionID: normalized.SessionID,
		InputUnits: normalized.InputUnits, OutputUnits: normalized.OutputUnits,
	}, nil
}

func arguments(invocation Invocation) []string {
	return []string{
		"--output-format", "stream-json", "--verbose", "--no-session-persistence", "--safe-mode",
		"--strict-mcp-config", "--mcp-config", `{"mcpServers":{}}`, "--tools", "",
		"--disallowedTools", "Bash,Edit,Write,WebFetch,WebSearch,Agent,Task,NotebookEdit,Skill,mcp__*",
		"--permission-mode", "dontAsk", "--max-turns", strconv.Itoa(invocation.Admission.Agent.MaxSteps),
		"--model", invocation.Model, "--print", "Complete the task supplied on standard input.",
	}
}

type normalizedResult struct {
	Output      string
	SessionID   string
	InputUnits  int
	OutputUnits int
	FailureCode string
}

func parseJSONL(output string) (normalizedResult, error) {
	result := normalizedResult{}
	initialized, terminal := false, false
	scanner := bufio.NewScanner(strings.NewReader(output))
	scanner.Buffer(make([]byte, 64*1024), maxLineSize)
	for scanner.Scan() {
		if terminal {
			return normalizedResult{}, errors.New("Claude emitted data after its terminal result")
		}
		var event struct {
			Type              string             `json:"type"`
			Subtype           string             `json:"subtype"`
			SessionID         string             `json:"session_id"`
			Version           string             `json:"claude_code_version"`
			PermissionMode    string             `json:"permissionMode"`
			Tools             *[]string          `json:"tools"`
			IsError           *bool              `json:"is_error"`
			Result            string             `json:"result"`
			Errors            []string           `json:"errors"`
			PermissionDenials *[]json.RawMessage `json:"permission_denials"`
			Message           struct {
				Content []struct {
					Type string `json:"type"`
				} `json:"content"`
			} `json:"message"`
			Usage *struct {
				InputTokens              int `json:"input_tokens"`
				OutputTokens             int `json:"output_tokens"`
				CacheReadInputTokens     int `json:"cache_read_input_tokens"`
				CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
			} `json:"usage"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
			return normalizedResult{}, err
		}
		if event.SessionID != "" {
			if !sessionIDPattern.MatchString(event.SessionID) || (result.SessionID != "" && result.SessionID != event.SessionID) {
				return normalizedResult{}, errors.New("invalid or changed Claude session ID")
			}
			result.SessionID = event.SessionID
		}
		switch event.Type {
		case "system":
			if event.Subtype == "init" {
				if initialized || !compatibleVersion(event.Version) || event.PermissionMode != "dontAsk" ||
					event.Tools == nil || len(*event.Tools) != 0 {
					return normalizedResult{}, errors.New("unexpected Claude initialization")
				}
				initialized = true
			}
		case "assistant":
			for _, content := range event.Message.Content {
				if content.Type == "tool_use" {
					return normalizedResult{}, errors.New("Claude attempted a disabled tool")
				}
			}
		case "result":
			if !initialized || event.SessionID == "" {
				return normalizedResult{}, errors.New("Claude result preceded initialization")
			}
			terminal = true
			if event.Subtype != "success" || event.IsError == nil || *event.IsError || len(event.Errors) > 0 ||
				event.PermissionDenials == nil || len(*event.PermissionDenials) > 0 {
				result.FailureCode = failureCode(event.Subtype)
				continue
			}
			if event.Usage == nil {
				return normalizedResult{}, errors.New("Claude usage is missing")
			}
			inputUnits, ok := sumUnits(event.Usage.InputTokens, event.Usage.CacheReadInputTokens, event.Usage.CacheCreationInputTokens)
			if !ok || event.Usage.OutputTokens < 0 || strings.TrimSpace(event.Result) == "" || len(event.Result) > 100*1024 {
				return normalizedResult{}, errors.New("invalid Claude result")
			}
			result.Output = event.Result
			result.InputUnits = inputUnits
			result.OutputUnits = event.Usage.OutputTokens
		}
	}
	if err := scanner.Err(); err != nil {
		return normalizedResult{}, err
	}
	if !terminal || result.SessionID == "" || (result.FailureCode == "" && result.Output == "") {
		return normalizedResult{}, errors.New("Claude output is incomplete")
	}
	return result, nil
}

func compatibleVersion(value string) bool {
	match := versionPattern.FindStringSubmatch(value)
	if len(match) != 2 {
		return false
	}
	patch, err := strconv.Atoi(match[1])
	return err == nil && patch >= 169 && patch <= 299
}

func sumUnits(values ...int) (int, bool) {
	total := 0
	maximum := int(^uint(0) >> 1)
	for _, value := range values {
		if value < 0 || total > maximum-value {
			return 0, false
		}
		total += value
	}
	return total, true
}

func failureCode(subtype string) string {
	switch subtype {
	case "error_max_turns":
		return "claude_max_turns"
	case "error_max_budget_usd":
		return "claude_budget_exceeded"
	case "error_max_structured_output_retries":
		return "claude_structured_output_failed"
	default:
		return "claude_execution_failed"
	}
}
