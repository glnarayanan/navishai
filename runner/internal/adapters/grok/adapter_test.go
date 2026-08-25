package grok

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net"
	"reflect"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

var testNow = time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)

type fakeInteractiveRunner struct {
	request     supervisor.Request
	toolRequest bool
}

func (runner *fakeInteractiveRunner) Interact(ctx context.Context, request supervisor.Request, client func(context.Context, io.ReadWriter) error) (supervisor.Result, error) {
	runner.request = request
	clientSide, serverSide := net.Pipe()
	defer clientSide.Close()
	done := make(chan error, 1)
	go func() { done <- serveACP(serverSide, runner.toolRequest) }()
	err := client(ctx, clientSide)
	_ = clientSide.Close()
	<-done
	return supervisor.Result{}, err
}

func serveACP(stream net.Conn, toolRequest bool) error {
	defer stream.Close()
	scanner := bufio.NewScanner(stream)
	write := func(value any) error {
		encoded, err := json.Marshal(value)
		if err != nil {
			return err
		}
		_, err = stream.Write(append(encoded, '\n'))
		return err
	}
	for scanner.Scan() {
		var request struct {
			ID     int             `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &request); err != nil {
			return err
		}
		switch request.Method {
		case "initialize":
			if err := write(map[string]any{"jsonrpc": "2.0", "id": request.ID, "result": map[string]any{"protocolVersion": 1, "_meta": map[string]string{"defaultAuthMethodId": "cached_token", "agentVersion": "grok 1.0.8 (abc123) [stable]"}}}); err != nil {
				return err
			}
		case "authenticate":
			if err := write(map[string]any{"jsonrpc": "2.0", "id": request.ID, "result": map[string]any{}}); err != nil {
				return err
			}
		case "session/new":
			if err := write(map[string]any{"jsonrpc": "2.0", "id": request.ID, "result": map[string]string{"sessionId": "3d07f334-88ef-4fe4-a640-421e3ba79921"}}); err != nil {
				return err
			}
		case "session/prompt":
			if toolRequest {
				if err := write(map[string]any{"jsonrpc": "2.0", "id": 91, "method": "session/request_permission", "params": map[string]any{}}); err != nil {
					return err
				}
				return nil
			}
			if err := write(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"sessionId": "3d07f334-88ef-4fe4-a640-421e3ba79921", "update": map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]string{"type": "text", "text": "Evidence-backed answer."}}}}); err != nil {
				return err
			}
			return write(map[string]any{"jsonrpc": "2.0", "id": request.ID, "result": map[string]any{"stopReason": "end_turn", "_meta": map[string]any{"usage": map[string]any{"inputTokens": 120, "outputTokens": 24, "usageIsIncomplete": false}}}})
		}
	}
	return scanner.Err()
}

func TestExecuteNegotiatesACPAndEmitsCanonicalOutput(t *testing.T) {
	runner := &fakeInteractiveRunner{}
	events := make([]protocol.CanonicalEvent, 0)
	result, err := New(func() time.Time { return testNow }).Execute(context.Background(), testInvocation(), runner, func(event protocol.CanonicalEvent) error {
		if err := event.Validate(); err != nil {
			t.Fatal(err)
		}
		events = append(events, event)
		return nil
	})
	if err != nil || result.Status != "completed" || result.Output != "Evidence-backed answer." || result.InputUnits != 120 || result.OutputUnits != 24 {
		t.Fatalf("result=%#v err=%v", result, err)
	}
	if !reflect.DeepEqual(runner.request.Arguments, []string{"agent", "--no-leader", "stdio"}) || runner.request.Input != nil || runner.request.EgressProfileKey != "model_api" {
		t.Fatalf("unexpected request %#v", runner.request)
	}
	types := make([]string, len(events))
	for index, event := range events {
		types[index] = event.EventType
	}
	if !reflect.DeepEqual(types, []string{"run.started", "output.produced", "usage.observed", "run.completed"}) {
		t.Fatalf("unexpected events %#v", types)
	}
}

func TestExecuteFailsBeforeOutputWhenUsageExceedsBudget(t *testing.T) {
	invocation := testInvocation()
	invocation.Admission.Routing.MaxOutputUnits = 23
	events := make([]protocol.CanonicalEvent, 0)
	result, err := New(func() time.Time { return testNow }).Execute(context.Background(), invocation, &fakeInteractiveRunner{}, func(event protocol.CanonicalEvent) error {
		events = append(events, event)
		return nil
	})
	if err != nil || result.FailureCode != "runtime_unit_budget_exceeded" || len(events) != 2 || events[1].EventType != "run.failed" {
		t.Fatalf("result=%#v events=%#v err=%v", result, events, err)
	}
}

func TestExecuteFailsClosedOnReverseClientRequest(t *testing.T) {
	runner := &fakeInteractiveRunner{toolRequest: true}
	events := make([]protocol.CanonicalEvent, 0)
	result, err := New(func() time.Time { return testNow }).Execute(context.Background(), testInvocation(), runner, func(event protocol.CanonicalEvent) error {
		events = append(events, event)
		return nil
	})
	if err != nil || result.Status != "failed" || result.FailureCode != "grok_policy_denied" || len(events) != 2 || events[1].EventType != "run.failed" {
		t.Fatalf("result=%#v events=%#v err=%v", result, events, err)
	}
}

func TestCompatibleVersionUsesMaintainedRange(t *testing.T) {
	if !compatibleVersion("grok 1.0.8 (abc123) [stable]") || compatibleVersion("grok 1.0.3 (old) [stable]") || compatibleVersion("grok 1.1.0 (new) [stable]") {
		t.Fatal("unexpected Grok compatibility result")
	}
}

func TestApplyUpdateRejectsProviderToolExtensions(t *testing.T) {
	for _, update := range []string{
		`{"update":{"type":"tool_call_delta_chunk"}}`,
		`{"event":{"session_update":"pending_interaction"}}`,
	} {
		if err := applyUpdate(json.RawMessage(update), &Result{}); err != errProhibitedOperation {
			t.Fatalf("expected prohibited operation for %s, got %v", update, err)
		}
	}
}

func testInvocation() Invocation {
	return Invocation{
		Admission: protocol.AdmissionRequest{
			ProtocolVersion: protocol.Version, RunID: "3d07f334-88ef-4fe4-a640-421e3ba79921", IdempotencyKey: "grok-test",
			WorkspaceKey: "c9bb966b-1fe9-4304-bd51-404e4fd9a09c",
			Task:         protocol.Task{TaskKey: "fae7db72-e33b-46b9-8f9e-9a0dfdd56661", Attempt: 1, Title: "Investigate", InputContext: "Case facts", ExpectedOutput: "Cited answer"},
			Agent:        protocol.AgentPolicy{RoleKey: "support_investigator", PolicyVersion: 1, Instructions: "Investigate.", AllowedTools: []string{"case_read"}, RuntimeProfileKey: "workspace_default", TimeoutSeconds: 300, MaxSteps: 10, MaxToolCalls: 20, ReviewPolicy: "required"},
			Routing:      protocol.RuntimeRouting{MaxInputUnits: 1_000_000, MaxOutputUnits: 1_000_000},
		},
		Executable: "/opt/grok", WorkingDir: "/work/run", GrokHome: "/runtime/grok", Model: "grok-code-fast-1",
		Prompt: "Investigate the case.", EgressProfileKey: "model_api",
	}
}
