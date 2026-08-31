package codex

import (
	"context"
	"errors"
	"reflect"
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

func TestExecuteBuildsConstrainedInvocationAndEmitsCanonicalOutput(t *testing.T) {
	runner := &fakeRunner{result: supervisor.Result{ExitCode: 0, StandardOutput: successfulJSONL}}
	events := make([]protocol.CanonicalEvent, 0)
	invocation := testInvocation()
	invocation.Credentials = map[string]string{"OPENAI_API_KEY": "sk-test-value"}
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
	if result.Status != "completed" || result.Output != "Cited answer." || result.InputUnits != 120 || result.OutputUnits != 24 {
		t.Fatalf("unexpected result %#v", result)
	}
	expectedArguments := []string{
		"exec", "--json", "--color", "never", "--sandbox", "read-only", "--ephemeral",
		"--ignore-user-config", "--ignore-rules", "-c", `approval_policy="never"`,
		"-c", `web_search="disabled"`,
		"-C", "/work/run", "-m", "gpt-5-codex", "-",
	}
	if !reflect.DeepEqual(runner.request.Arguments, expectedArguments) || string(runner.request.Input) != "Investigate the case." {
		t.Fatalf("unexpected process request %#v", runner.request)
	}
	if !reflect.DeepEqual(runner.request.Credentials, map[string]string{"CODEX_HOME": "/runtime/codex", "OPENAI_API_KEY": "sk-test-value"}) {
		t.Fatalf("unexpected credential environment %#v", runner.request.Credentials)
	}
	if runner.request.EgressProfileKey != "model_api" {
		t.Fatalf("unexpected egress profile %q", runner.request.EgressProfileKey)
	}
	eventTypes := make([]string, len(events))
	for index, event := range events {
		eventTypes[index] = event.EventType
		if event.Sequence != index+2 {
			t.Fatalf("unexpected sequence %d", event.Sequence)
		}
	}
	expectedTypes := []string{"run.started", "tool.completed", "output.produced", "usage.observed", "run.completed"}
	if !reflect.DeepEqual(eventTypes, expectedTypes) {
		t.Fatalf("unexpected events %#v", eventTypes)
	}
}

func TestRuntimeTestInvocationDisablesShellImplementations(t *testing.T) {
	invocation := testInvocation()
	invocation.DisableTools = true
	actual := arguments(invocation)
	wanted := []string{"--disable", "shell_tool", "--disable", "unified_exec"}

	found := false
	for index := 0; index <= len(actual)-len(wanted); index++ {
		if reflect.DeepEqual(actual[index:index+len(wanted)], wanted) {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("runtime test did not disable shell tools: %#v", actual)
	}
}

func TestExecuteFailsBeforeOutputWhenUsageExceedsBudget(t *testing.T) {
	invocation := testInvocation()
	invocation.Admission.Routing.MaxInputUnits = 119
	events := make([]protocol.CanonicalEvent, 0)
	result, err := New(func() time.Time { return testNow }).Execute(context.Background(), invocation,
		&fakeRunner{result: supervisor.Result{StandardOutput: successfulJSONL}},
		func(event protocol.CanonicalEvent) error { events = append(events, event); return nil })
	if err != nil || result.FailureCode != "runtime_unit_budget_exceeded" || len(events) != 2 || events[1].EventType != "run.failed" {
		t.Fatalf("result=%#v events=%#v err=%v", result, events, err)
	}
}

func TestExecuteFailsClosedForMalformedOutputAndProcessBounds(t *testing.T) {
	tests := []struct {
		name       string
		process    supervisor.Result
		processErr error
		status     string
		eventType  string
	}{
		{name: "malformed", process: supervisor.Result{StandardOutput: `{"type":"turn.completed"}`}, status: "failed", eventType: "run.failed"},
		{name: "nonzero", process: supervisor.Result{ExitCode: 1, StandardOutput: successfulJSONL}, status: "failed", eventType: "run.failed"},
		{name: "timeout", process: supervisor.Result{TimedOut: true}, status: "timed_out", eventType: "run.timed_out"},
		{name: "canceled", process: supervisor.Result{Canceled: true}, status: "canceled", eventType: "run.canceled"},
		{name: "supervisor", processErr: errors.New("denied"), status: "failed", eventType: "run.failed"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			runner := &fakeRunner{result: test.process, err: test.processErr}
			events := make([]protocol.CanonicalEvent, 0)
			result, err := New(func() time.Time { return testNow }).Execute(
				context.Background(), testInvocation(), runner,
				func(event protocol.CanonicalEvent) error { events = append(events, event); return nil },
			)
			if err != nil || result.Status != test.status || len(events) != 2 || events[1].EventType != test.eventType {
				t.Fatalf("result=%#v events=%#v err=%v", result, events, err)
			}
		})
	}
}

func TestParserIgnoresUnknownEventsButRejectsFailedOrIncompleteTurns(t *testing.T) {
	withUnknown := `{"type":"future.event","new_field":true}` + "\n" + successfulJSONL
	if result, err := parseJSONL(withUnknown); err != nil || result.ThreadID == "" {
		t.Fatalf("unexpected tolerant parse result=%#v err=%v", result, err)
	}
	for _, output := range []string{
		`{"type":"turn.failed","error":{"message":"failed"}}`,
		`{"type":"thread.started","thread_id":"3d07f334-88ef-4fe4-a640-421e3ba79921"}`,
		"not-json",
	} {
		if _, err := parseJSONL(output); err == nil {
			t.Fatalf("expected output to fail: %s", output)
		}
	}
}

func testInvocation() Invocation {
	return Invocation{
		Admission: protocol.AdmissionRequest{
			ProtocolVersion: protocol.Version, RunID: "3d07f334-88ef-4fe4-a640-421e3ba79921",
			IdempotencyKey: "codex-test", WorkspaceKey: "c9bb966b-1fe9-4304-bd51-404e4fd9a09c",
			Task: protocol.Task{TaskKey: "fae7db72-e33b-46b9-8f9e-9a0dfdd56661", Attempt: 1,
				Title: "Investigate", InputContext: "Case facts", ExpectedOutput: "Cited answer"},
			Agent: protocol.AgentPolicy{RoleKey: "support_investigator", PolicyVersion: 1,
				Instructions: "Investigate.", AllowedTools: []string{"case_read"}, RuntimeProfileKey: "workspace_default",
				TimeoutSeconds: 300, MaxSteps: 10, MaxToolCalls: 20, ReviewPolicy: "required"},
			Routing: protocol.RuntimeRouting{MaxInputUnits: 1_000_000, MaxOutputUnits: 1_000_000},
		},
		Executable: "/opt/codex", WorkingDir: "/work/run", CodexHome: "/runtime/codex",
		Model: "gpt-5-codex", Prompt: "Investigate the case.", EgressProfileKey: "model_api",
	}
}

const successfulJSONL = `{"type":"thread.started","thread_id":"3d07f334-88ef-4fe4-a640-421e3ba79921"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"command_execution","status":"completed"}}
{"type":"item.completed","item":{"id":"item_1","type":"reasoning","text":"Summary only"}}
{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Cited answer."}}
{"type":"turn.completed","usage":{"input_tokens":120,"cached_input_tokens":100,"output_tokens":24,"reasoning_output_tokens":4}}
`
