package cursor

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

const (
	AdapterKey  = "cursor_acp_subscription"
	minVersion  = "2026.3.11"
	maxVersion  = "2026.12.31"
	maxLineSize = 128 * 1024
)

var (
	sessionIDPattern       = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	versionPattern         = regexp.MustCompile(`\b(\d{4})\.(\d{1,2})\.(\d{1,2})\b`)
	errProhibitedOperation = errors.New("Cursor requested a prohibited operation")
)

type Invocation struct {
	Admission        protocol.AdmissionRequest
	Executable       string
	WorkingDir       string
	CursorHome       string
	Model            string
	Prompt           string
	EgressProfileKey string
}

type Result struct {
	Status        string
	Output        string
	SessionID     string
	InputUnits    int
	OutputUnits   int
	UsageObserved bool
	FailureCode   string
}

type Adapter struct{ now func() time.Time }

func Definition() runtimecatalog.Definition {
	return runtimecatalog.Definition{
		AdapterKey: AdapterKey, ProtocolVersion: protocol.Version, ExecutableNames: []string{"cursor-agent", "agent"},
		VersionArguments: []string{"--version"}, Capabilities: []string{"acp", runtimecatalog.RuntimeTestCapability, "structured_output", "tool_calling"},
		EffectiveModel: "runtime_default", ConfigurationFingerprint: strings.Repeat("0", 64),
		MinimumVersion: minVersion, MaximumVersion: maxVersion,
	}
}

func New(now func() time.Time) *Adapter {
	if now == nil {
		now = time.Now
	}
	return &Adapter{now: now}
}

func (adapter *Adapter) Execute(ctx context.Context, invocation Invocation, runner adapters.InteractiveProcessRunner, emit func(protocol.CanonicalEvent) error) (Result, error) {
	if runner == nil || emit == nil || strings.TrimSpace(invocation.Prompt) == "" || invocation.CursorHome == "" || invocation.EgressProfileKey == "" {
		return Result{}, errors.New("invalid Cursor invocation")
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
	if err := emitEvent("run.started", map[string]any{"adapter": AdapterKey, "scenario": "subscription", "attempt": invocation.Admission.Task.Attempt}); err != nil {
		return Result{}, err
	}
	normalized := Result{}
	arguments := []string{"acp"}
	if invocation.Model != "" {
		arguments = []string{"--model", invocation.Model, "acp"}
	}
	process, processErr := runner.Interact(ctx, supervisor.Request{
		Executable: invocation.Executable, Arguments: arguments, WorkingDir: invocation.WorkingDir, HomeDir: invocation.CursorHome,
		EgressProfileKey: invocation.EgressProfileKey,
	}, func(exchangeContext context.Context, stream io.ReadWriter) error {
		var err error
		normalized, err = exchange(exchangeContext, stream, invocation)
		if err != nil {
			if errors.Is(err, errProhibitedOperation) {
				normalized.FailureCode = "cursor_policy_denied"
			} else {
				normalized.FailureCode = "cursor_malformed_output"
			}
		}
		return err
	})
	if process.TimedOut {
		return Result{Status: "timed_out", FailureCode: "cursor_timed_out"}, emitEvent("run.timed_out", map[string]any{"reason": "Cursor exceeded the run deadline."})
	}
	if process.Canceled {
		return Result{Status: "canceled", FailureCode: "cursor_canceled"}, emitEvent("run.canceled", map[string]any{"reason": "Cursor was canceled."})
	}
	if processErr != nil || process.ExitCode != 0 || normalized.FailureCode != "" {
		code := normalized.FailureCode
		if code == "" {
			code = "cursor_process_failed"
		}
		return Result{Status: "failed", FailureCode: code}, emitEvent("run.failed", map[string]any{"code": code, "retryable": false})
	}
	if normalized.UsageObserved && !adapters.WithinUnitBudget(invocation.Admission, normalized.InputUnits, normalized.OutputUnits) {
		return Result{Status: "failed", FailureCode: "runtime_unit_budget_exceeded"}, emitEvent("run.failed", map[string]any{"code": "runtime_unit_budget_exceeded", "retryable": false})
	}
	if err := emitEvent("output.produced", map[string]any{"text": normalized.Output}); err != nil {
		return Result{}, err
	}
	if normalized.UsageObserved {
		if err := emitEvent("usage.observed", map[string]any{"input_units": normalized.InputUnits, "output_units": normalized.OutputUnits}); err != nil {
			return Result{}, err
		}
	}
	if err := emitEvent("run.completed", map[string]any{"outcome": "completed"}); err != nil {
		return Result{}, err
	}
	normalized.Status = "completed"
	return normalized, nil
}

type rpcEnvelope struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
	Result  json.RawMessage `json:"result"`
	Error   json.RawMessage `json:"error"`
}

func exchange(ctx context.Context, stream io.ReadWriter, invocation Invocation) (Result, error) {
	scanner := bufio.NewScanner(stream)
	scanner.Buffer(make([]byte, 64*1024), maxLineSize)
	write := func(id int, method string, params any) error {
		encoded, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
		if err != nil {
			return err
		}
		_, err = stream.Write(append(encoded, '\n'))
		return err
	}
	if err := write(1, "initialize", map[string]any{
		"protocolVersion":    1,
		"clientCapabilities": map[string]any{"fs": map[string]bool{"readTextFile": false, "writeTextFile": false}, "terminal": false},
		"clientInfo":         map[string]string{"name": "navishai", "version": protocol.Version},
	}); err != nil {
		return Result{}, err
	}
	initResponse, err := response(ctx, scanner, stream, 1, nil)
	if err != nil {
		return Result{}, err
	}
	var initialized struct {
		ProtocolVersion int `json:"protocolVersion"`
		AuthMethods     []struct {
			ID string `json:"id"`
		} `json:"authMethods"`
		Meta struct {
			AgentVersion string `json:"agentVersion"`
		} `json:"_meta"`
	}
	if json.Unmarshal(initResponse, &initialized) != nil || initialized.ProtocolVersion != 1 || !hasAuthMethod(initialized.AuthMethods, "cursor_login") ||
		(initialized.Meta.AgentVersion != "" && !compatibleVersion(initialized.Meta.AgentVersion)) {
		return Result{FailureCode: "cursor_unapproved_runtime"}, nil
	}
	if err := write(2, "authenticate", map[string]string{"methodId": "cursor_login"}); err != nil {
		return Result{}, err
	}
	if _, err := response(ctx, scanner, stream, 2, nil); err != nil {
		return Result{FailureCode: "cursor_not_authenticated"}, nil
	}
	if err := write(3, "session/new", map[string]any{"cwd": invocation.WorkingDir, "mcpServers": []any{}}); err != nil {
		return Result{}, err
	}
	newResponse, err := response(ctx, scanner, stream, 3, nil)
	if err != nil {
		return Result{}, err
	}
	var session struct {
		SessionID string `json:"sessionId"`
	}
	if json.Unmarshal(newResponse, &session) != nil || !sessionIDPattern.MatchString(session.SessionID) {
		return Result{}, errors.New("invalid Cursor session")
	}
	if err := write(4, "session/prompt", map[string]any{"sessionId": session.SessionID, "prompt": []map[string]string{{"type": "text", "text": invocation.Prompt}}}); err != nil {
		return Result{}, err
	}
	result := Result{SessionID: session.SessionID}
	promptResponse, err := response(ctx, scanner, stream, 4, &result)
	if err != nil {
		return Result{}, err
	}
	var terminal struct {
		StopReason string `json:"stopReason"`
		Usage      *struct {
			InputTokens  int `json:"inputTokens"`
			OutputTokens int `json:"outputTokens"`
		} `json:"usage"`
		Meta struct {
			Usage *struct {
				InputTokens  int `json:"inputTokens"`
				OutputTokens int `json:"outputTokens"`
			} `json:"usage"`
		} `json:"_meta"`
	}
	if json.Unmarshal(promptResponse, &terminal) != nil || terminal.StopReason == "" {
		return Result{}, errors.New("invalid Cursor terminal result")
	}
	if terminal.StopReason != "end_turn" {
		result.Output = ""
		result.FailureCode = terminalFailureCode(terminal.StopReason)
		return result, nil
	}
	if strings.TrimSpace(result.Output) == "" || len(result.Output) > 100*1024 {
		return Result{}, errors.New("invalid Cursor terminal result")
	}
	usage := terminal.Usage
	if usage == nil {
		usage = terminal.Meta.Usage
	}
	if usage != nil {
		if usage.InputTokens < 0 || usage.OutputTokens < 0 {
			return Result{}, errors.New("invalid Cursor usage")
		}
		result.InputUnits, result.OutputUnits, result.UsageObserved = usage.InputTokens, usage.OutputTokens, true
	}
	return result, nil
}

func response(ctx context.Context, scanner *bufio.Scanner, stream io.Writer, wantedID int, result *Result) (json.RawMessage, error) {
	for scanner.Scan() {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		var message rpcEnvelope
		if json.Unmarshal(scanner.Bytes(), &message) != nil || message.JSONRPC != "2.0" {
			return nil, errors.New("invalid Cursor ACP message")
		}
		if len(message.ID) > 0 && message.Method != "" {
			denial, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(message.ID), "result": map[string]any{"outcome": map[string]string{"outcome": "cancelled"}}})
			_, _ = stream.Write(append(denial, '\n'))
			return nil, errProhibitedOperation
		}
		if message.Method == "session/update" {
			if result != nil {
				if err := applyUpdate(message.Params, result); err != nil {
					return nil, err
				}
			}
			continue
		}
		if strings.HasPrefix(message.Method, "cursor/") {
			continue
		}
		if len(message.ID) == 0 {
			continue
		}
		var id int
		if json.Unmarshal(message.ID, &id) != nil || id != wantedID {
			return nil, errors.New("unexpected Cursor ACP response")
		}
		if len(message.Error) > 0 && string(message.Error) != "null" {
			return nil, errors.New("Cursor ACP request failed")
		}
		return message.Result, nil
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return nil, io.ErrUnexpectedEOF
}

func applyUpdate(raw json.RawMessage, result *Result) error {
	var update struct {
		Update struct {
			SessionUpdate string `json:"sessionUpdate"`
			Content       struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"update"`
	}
	if json.Unmarshal(raw, &update) != nil {
		return errors.New("invalid Cursor update")
	}
	switch update.Update.SessionUpdate {
	case "agent_message_chunk":
		if update.Update.Content.Type != "text" {
			return errors.New("invalid Cursor output chunk")
		}
		result.Output += update.Update.Content.Text
		if len(result.Output) > 100*1024 {
			return errors.New("Cursor output exceeded limit")
		}
	case "tool_call", "tool_call_update":
		return errProhibitedOperation
	}
	return nil
}

func hasAuthMethod(methods []struct {
	ID string `json:"id"`
}, wanted string) bool {
	for _, method := range methods {
		if method.ID == wanted {
			return true
		}
	}
	return false
}

func compatibleVersion(value string) bool {
	if !runtimecatalog.ValidObservedVersion(value) {
		return false
	}
	match := versionPattern.FindStringSubmatch(value)
	if len(match) != 4 {
		return false
	}
	_, err := time.Parse("2006.1.2", strings.Join(match[1:], "."))
	return err == nil && len(value) <= 8*1024
}

func terminalFailureCode(stopReason string) string {
	switch stopReason {
	case "max_tokens", "max_turn_requests":
		return "cursor_limit_reached"
	case "refusal":
		return "cursor_refused"
	case "cancelled":
		return "cursor_canceled"
	default:
		return "cursor_execution_failed"
	}
}
