package codex

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

const (
	AdapterKey  = "codex_subscription"
	minVersion  = "0.149.0"
	maxVersion  = "0.149.99"
	maxLineSize = 128 * 1024
)

var threadIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

type Invocation struct {
	Admission        protocol.AdmissionRequest
	Executable       string
	WorkingDir       string
	CodexHome        string
	Model            string
	Prompt           string
	DisableTools     bool
	Credentials      map[string]string
	EgressProfileKey string
}

type Result struct {
	Status      string
	Output      string
	ThreadID    string
	InputUnits  int
	OutputUnits int
	FailureCode string
}

type Adapter struct {
	now func() time.Time
}

func Definition() runtimecatalog.Definition {
	return runtimecatalog.Definition{
		AdapterKey: AdapterKey, ProtocolVersion: protocol.Version, ExecutableNames: []string{"codex"},
		VersionArguments: []string{"--version"}, AccountArguments: []string{"login", "status"},
		AccountMarker:      "Logged in using ChatGPT",
		AccountEnvironment: []string{"CODEX_HOME"},
		AccountMetadata:    map[string]string{"authentication": "chatgpt_subscription"},
		Capabilities:       []string{runtimecatalog.RuntimeTestCapability, "structured_output", "tool_calling"},
		Transport:          runtimecatalog.TransportManagedProcess,
		ExecutionMode:      protocol.ExecutionModeStrongIsolated,
		EffectiveModel:     "runtime_default", ConfigurationFingerprint: strings.Repeat("0", 64),
		MinimumVersion: minVersion, MaximumVersion: maxVersion,
	}
}

func New(now func() time.Time) *Adapter {
	if now == nil {
		now = time.Now
	}
	return &Adapter{now: now}
}

func (adapter *Adapter) Execute(ctx context.Context, invocation Invocation, runner adapters.ProcessRunner, emit func(protocol.CanonicalEvent) error) (Result, error) {
	if runner == nil || emit == nil || strings.TrimSpace(invocation.Prompt) == "" ||
		invocation.CodexHome == "" || invocation.EgressProfileKey == "" {
		return Result{}, errors.New("invalid Codex invocation")
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
	credentials := map[string]string{"CODEX_HOME": invocation.CodexHome}
	for key, value := range invocation.Credentials {
		credentials[key] = value
	}
	process, processErr := runner.Run(ctx, supervisor.Request{
		Executable: invocation.Executable, Arguments: arguments(invocation), WorkingDir: invocation.WorkingDir,
		HomeDir: invocation.CodexHome, Input: []byte(invocation.Prompt), Credentials: credentials,
		EgressProfileKey: invocation.EgressProfileKey,
	})
	if process.TimedOut {
		return Result{Status: "timed_out", FailureCode: "codex_timed_out"}, emitEvent("run.timed_out", map[string]any{"reason": "Codex exceeded the run deadline."})
	}
	if process.Canceled {
		return Result{Status: "canceled", FailureCode: "codex_canceled"}, emitEvent("run.canceled", map[string]any{"reason": "Codex was canceled."})
	}
	if processErr != nil {
		return Result{Status: "failed", FailureCode: "codex_process_failed"}, emitEvent("run.failed", map[string]any{"code": "codex_process_failed", "retryable": false})
	}
	normalized, parseErr := parseJSONL(process.StandardOutput)
	if parseErr != nil || process.ExitCode != 0 {
		code := "codex_failed"
		if parseErr != nil {
			code = "codex_malformed_output"
		}
		return Result{Status: "failed", FailureCode: code}, emitEvent("run.failed", map[string]any{"code": code, "retryable": false})
	}
	if !adapters.WithinUnitBudget(invocation.Admission, normalized.InputUnits, normalized.OutputUnits) {
		return Result{Status: "failed", FailureCode: "runtime_unit_budget_exceeded"}, emitEvent("run.failed", map[string]any{"code": "runtime_unit_budget_exceeded", "retryable": false})
	}
	for _, tool := range normalized.Tools {
		if err := emitEvent("tool.completed", map[string]any{"tool": tool.Name, "result": tool.Result}); err != nil {
			return Result{}, err
		}
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
		Status: "completed", Output: normalized.Output, ThreadID: normalized.ThreadID,
		InputUnits: normalized.InputUnits, OutputUnits: normalized.OutputUnits,
	}, nil
}

func arguments(invocation Invocation) []string {
	values := []string{
		"exec", "--json", "--color", "never", "--sandbox", "read-only", "--ephemeral",
		"--ignore-user-config", "--ignore-rules", "-c", `approval_policy="never"`,
		"-c", `web_search="disabled"`,
	}
	if invocation.DisableTools {
		values = append(values, "--disable", "shell_tool", "--disable", "unified_exec")
	}
	values = append(values, "-C", invocation.WorkingDir)
	if invocation.Model != "" {
		values = append(values, "-m", invocation.Model)
	}
	return append(values, "-")
}

type toolResult struct {
	Name   string
	Result string
}

type normalizedResult struct {
	Output      string
	ThreadID    string
	InputUnits  int
	OutputUnits int
	Tools       []toolResult
}

func parseJSONL(output string) (normalizedResult, error) {
	result := normalizedResult{}
	completed := false
	scanner := bufio.NewScanner(strings.NewReader(output))
	scanner.Buffer(make([]byte, 64*1024), maxLineSize)
	for scanner.Scan() {
		var event struct {
			Type     string `json:"type"`
			ThreadID string `json:"thread_id"`
			Item     struct {
				Type   string `json:"type"`
				Text   string `json:"text"`
				Status string `json:"status"`
			} `json:"item"`
			Usage struct {
				InputTokens  int `json:"input_tokens"`
				OutputTokens int `json:"output_tokens"`
			} `json:"usage"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
			return normalizedResult{}, err
		}
		switch event.Type {
		case "thread.started":
			if !threadIDPattern.MatchString(event.ThreadID) {
				return normalizedResult{}, errors.New("invalid Codex thread ID")
			}
			if result.ThreadID != "" && result.ThreadID != event.ThreadID {
				return normalizedResult{}, errors.New("Codex thread ID changed")
			}
			result.ThreadID = event.ThreadID
		case "item.completed":
			switch event.Item.Type {
			case "agent_message":
				result.Output = event.Item.Text
			case "command_execution", "file_change", "mcp_tool_call", "web_search", "collab_tool_call":
				status := event.Item.Status
				if status == "" {
					status = "completed"
				}
				result.Tools = append(result.Tools, toolResult{Name: event.Item.Type, Result: status})
			}
		case "turn.completed":
			completed = true
			result.InputUnits = event.Usage.InputTokens
			result.OutputUnits = event.Usage.OutputTokens
		case "turn.failed", "error":
			return normalizedResult{}, errors.New("Codex turn failed")
		}
	}
	if err := scanner.Err(); err != nil {
		return normalizedResult{}, err
	}
	if !completed || result.ThreadID == "" || strings.TrimSpace(result.Output) == "" ||
		len(result.Output) > 100*1024 || result.InputUnits < 0 || result.OutputUnits < 0 {
		return normalizedResult{}, errors.New("Codex output is incomplete")
	}
	return result, nil
}
