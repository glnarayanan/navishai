package claude

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

var testNow = time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)

type fakeRunner struct {
	request supervisor.Request
	result  supervisor.Result
	err     error
}

func (runner *fakeRunner) Run(_ context.Context, request supervisor.Request) (supervisor.Result, error) {
	runner.request = request
	return runner.result, runner.err
}

func TestDefinitionAcceptsOnlyVerifiedClaudeSubscriptions(t *testing.T) {
	valid := `{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty","subscriptionType":"max"}`
	if !validSubscriptionStatus(valid) {
		t.Fatal("expected valid subscription status")
	}
	for _, status := range []string{
		`{"loggedIn":false,"authMethod":"oauth_token","apiProvider":"firstParty","subscriptionType":"pro"}`,
		`{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty","subscriptionType":"pro"}`,
		`{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"bedrock","subscriptionType":"team"}`,
		`{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty"}`,
		`not-json`,
	} {
		if validSubscriptionStatus(status) {
			t.Fatalf("accepted invalid status %s", status)
		}
	}
}

func TestExecuteBuildsConstrainedInvocationAndEmitsCanonicalOutput(t *testing.T) {
	runner := &fakeRunner{result: supervisor.Result{ExitCode: 0, StandardOutput: successfulJSONL}}
	events := make([]protocol.CanonicalEvent, 0)
	invocation := testInvocation()
	invocation.Credentials = map[string]string{"ANTHROPIC_API_KEY": "sk-ant-test-value"}
	result, err := New(func() time.Time { return testNow }).Execute(
		context.Background(), invocation, runner,
		func(event protocol.CanonicalEvent) error {
			if err := event.Validate(); err != nil {
				t.Fatalf("invalid canonical event %#v: %v", event, err)
			}
			events = append(events, event)
			return nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Status != "completed" || result.Output != "Evidence-backed answer." || result.InputUnits != 145 || result.OutputUnits != 24 {
		t.Fatalf("unexpected result %#v", result)
	}
	expectedArguments := []string{
		"--output-format", "stream-json", "--verbose", "--no-session-persistence", "--safe-mode",
		"--strict-mcp-config", "--mcp-config", `{"mcpServers":{}}`, "--tools", "",
		"--disallowedTools", "Bash,Edit,Write,WebFetch,WebSearch,Agent,Task,NotebookEdit,Skill,mcp__*",
		"--permission-mode", "dontAsk", "--max-turns", "10", "--model", "sonnet", "--print",
		"Complete the task supplied on standard input.",
	}
	if !reflect.DeepEqual(runner.request.Arguments, expectedArguments) || string(runner.request.Input) != "Investigate the case." {
		t.Fatalf("unexpected process request %#v", runner.request)
	}
	if !reflect.DeepEqual(runner.request.Credentials, map[string]string{"ANTHROPIC_API_KEY": "sk-ant-test-value", "CLAUDE_CONFIG_DIR": "/runtime/claude"}) ||
		runner.request.EgressProfileKey != "model_api" {
		t.Fatalf("unexpected execution boundary %#v", runner.request)
	}
	eventTypes := make([]string, len(events))
	for index, event := range events {
		eventTypes[index] = event.EventType
		if event.Sequence != index+2 {
			t.Fatalf("unexpected sequence %d", event.Sequence)
		}
	}
	if !reflect.DeepEqual(eventTypes, []string{"run.started", "output.produced", "usage.observed", "run.completed"}) {
		t.Fatalf("unexpected events %#v", eventTypes)
	}
}

func TestExecuteFailsBeforeOutputWhenUsageExceedsBudget(t *testing.T) {
	invocation := testInvocation()
	invocation.Admission.Routing.MaxInputUnits = 144
	events := make([]protocol.CanonicalEvent, 0)
	result, err := New(func() time.Time { return testNow }).Execute(context.Background(), invocation,
		&fakeRunner{result: supervisor.Result{StandardOutput: successfulJSONL}},
		func(event protocol.CanonicalEvent) error { events = append(events, event); return nil })
	if err != nil || result.FailureCode != "runtime_unit_budget_exceeded" || len(events) != 2 || events[1].EventType != "run.failed" {
		t.Fatalf("result=%#v events=%#v err=%v", result, events, err)
	}
}

func TestExecuteNormalizesTerminalFailuresAndProcessBounds(t *testing.T) {
	tests := []struct {
		name       string
		process    supervisor.Result
		processErr error
		status     string
		code       string
		eventType  string
	}{
		{name: "loop failure", process: supervisor.Result{ExitCode: 1, StandardOutput: failedJSONL}, status: "failed", code: "claude_max_turns", eventType: "run.failed"},
		{name: "malformed", process: supervisor.Result{StandardOutput: `{"type":"result"}`}, status: "failed", code: "claude_malformed_output", eventType: "run.failed"},
		{name: "nonzero", process: supervisor.Result{ExitCode: 1, StandardOutput: successfulJSONL}, status: "failed", code: "claude_failed", eventType: "run.failed"},
		{name: "timeout", process: supervisor.Result{TimedOut: true}, status: "timed_out", code: "claude_timed_out", eventType: "run.timed_out"},
		{name: "canceled", process: supervisor.Result{Canceled: true}, status: "canceled", code: "claude_canceled", eventType: "run.canceled"},
		{name: "supervisor", processErr: errors.New("denied"), status: "failed", code: "claude_process_failed", eventType: "run.failed"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			runner := &fakeRunner{result: test.process, err: test.processErr}
			events := make([]protocol.CanonicalEvent, 0)
			result, err := New(func() time.Time { return testNow }).Execute(
				context.Background(), testInvocation(), runner,
				func(event protocol.CanonicalEvent) error { events = append(events, event); return nil },
			)
			if err != nil || result.Status != test.status || result.FailureCode != test.code || len(events) != 2 || events[1].EventType != test.eventType {
				t.Fatalf("result=%#v events=%#v err=%v", result, events, err)
			}
		})
	}
}

func TestParserIgnoresUnknownEventsButRejectsBoundaryChanges(t *testing.T) {
	withUnknown := `{"type":"future.event","new_field":true}` + "\n" + successfulJSONL
	if result, err := parseJSONL(withUnknown); err != nil || result.SessionID == "" {
		t.Fatalf("unexpected tolerant parse result=%#v err=%v", result, err)
	}
	for _, output := range []string{
		strings.Replace(successfulJSONL, `"claude_code_version":"2.1.241"`, `"claude_code_version":"2.1"`, 1),
		strings.Replace(successfulJSONL, `"output_tokens":24`, `"output_tokens":-1`, 1),
		strings.Replace(successfulJSONL, `"usage":{"input_tokens":20,"cache_read_input_tokens":120,"cache_creation_input_tokens":5,"output_tokens":24},`, "", 1),
		strings.Replace(successfulJSONL, `"session_id":"3d07f334-88ef-4fe4-a640-421e3ba79921","is_error"`, `"session_id":"4d07f334-88ef-4fe4-a640-421e3ba79921","is_error"`, 1),
		successfulJSONL + `{"type":"future.after_terminal"}`,
		`{"type":"system","subtype":"init","session_id":"3d07f334-88ef-4fe4-a640-421e3ba79921","claude_code_version":"2.1.241","permissionMode":"default","tools":[]}` + "\n" + successResult,
		`{"type":"system","subtype":"init","session_id":"3d07f334-88ef-4fe4-a640-421e3ba79921","claude_code_version":"2.1.241","permissionMode":"dontAsk","tools":["Bash"]}` + "\n" + successResult,
		`{"type":"system","subtype":"init","session_id":"3d07f334-88ef-4fe4-a640-421e3ba79921","claude_code_version":"2.1.241","permissionMode":"dontAsk","tools":[]}` + "\n" +
			`{"type":"assistant","session_id":"3d07f334-88ef-4fe4-a640-421e3ba79921","message":{"content":[{"type":"tool_use","name":"Bash"}]}}` + "\n" + successResult,
		`not-json`,
	} {
		if _, err := parseJSONL(output); err == nil {
			t.Fatalf("expected output to fail: %s", output)
		}
	}
	denied := strings.Replace(successfulJSONL, `"permission_denials":[]`, `"permission_denials":[{"tool_name":"Bash"}]`, 1)
	if result, err := parseJSONL(denied); err != nil || result.FailureCode != "claude_execution_failed" {
		t.Fatalf("permission denial result=%#v err=%v", result, err)
	}
}

func testInvocation() Invocation {
	return Invocation{
		Admission: protocol.AdmissionRequest{
			ProtocolVersion: protocol.AdmissionVersion, RunID: "3d07f334-88ef-4fe4-a640-421e3ba79921",
			IdempotencyKey: "claude-test", WorkspaceKey: "c9bb966b-1fe9-4304-bd51-404e4fd9a09c",
			Task: protocol.Task{TaskKey: "fae7db72-e33b-46b9-8f9e-9a0dfdd56661", Attempt: 1,
				Title: "Investigate", InputContext: "Case facts", ExpectedOutput: "Cited answer"},
			Agent: protocol.AgentPolicy{RoleKey: "support_investigator", PolicyVersion: 1,
				Instructions: "Investigate.", AllowedTools: []string{"case_read"}, RuntimeProfileKey: "workspace_default",
				TimeoutSeconds: 300, MaxSteps: 10, MaxToolCalls: 20, ReviewPolicy: "required"},
			Routing: protocol.RuntimeRouting{
				ExecutionMode: protocol.ExecutionModeHostTrusted, IsolationPolicy: protocol.IsolationPolicyHostTrustedAllowed,
				MaxInputUnits: 1_000_000, MaxOutputUnits: 1_000_000,
			},
		},
		Executable: "/opt/claude", WorkingDir: "/work/run", ClaudeConfigDir: "/runtime/claude",
		Model: "sonnet", Prompt: "Investigate the case.", EgressProfileKey: "model_api",
	}
}

func TestCompatibleVersionAcceptsFutureVersionsWithBoundedEvidence(t *testing.T) {
	if !compatibleVersion("Claude Code 2.1.168") || !compatibleVersion("Claude Code 3.0.0") || compatibleVersion("Claude Code development build") {
		t.Fatal("unexpected observed-version result")
	}
}

const successResult = `{"type":"result","subtype":"success","session_id":"3d07f334-88ef-4fe4-a640-421e3ba79921","is_error":false,"result":"Evidence-backed answer.","usage":{"input_tokens":20,"cache_read_input_tokens":120,"cache_creation_input_tokens":5,"output_tokens":24},"permission_denials":[]}`

const successfulJSONL = `{"type":"system","subtype":"init","session_id":"3d07f334-88ef-4fe4-a640-421e3ba79921","claude_code_version":"2.1.241","permissionMode":"dontAsk","tools":[]}
{"type":"assistant","session_id":"3d07f334-88ef-4fe4-a640-421e3ba79921","message":{"content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"Evidence-backed answer."}]}}
` + successResult + "\n"

const failedJSONL = `{"type":"system","subtype":"init","session_id":"3d07f334-88ef-4fe4-a640-421e3ba79921","claude_code_version":"2.1.241","permissionMode":"dontAsk","tools":[]}
{"type":"result","subtype":"error_max_turns","session_id":"3d07f334-88ef-4fe4-a640-421e3ba79921","is_error":true,"errors":["maximum turns reached"],"permission_denials":[]}
`
