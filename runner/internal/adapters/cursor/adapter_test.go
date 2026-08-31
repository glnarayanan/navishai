package cursor

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
	omitUsage   bool
}

func (runner *fakeInteractiveRunner) Interact(ctx context.Context, request supervisor.Request, client func(context.Context, io.ReadWriter) error) (supervisor.Result, error) {
	runner.request = request
	clientSide, serverSide := net.Pipe()
	done := make(chan error, 1)
	go func() { done <- serveACP(serverSide, runner.toolRequest, runner.omitUsage) }()
	err := client(ctx, clientSide)
	_ = clientSide.Close()
	<-done
	return supervisor.Result{}, err
}

func serveACP(stream net.Conn, toolRequest, omitUsage bool) error {
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
			ID     int    `json:"id"`
			Method string `json:"method"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &request); err != nil {
			return err
		}
		switch request.Method {
		case "initialize":
			if err := write(map[string]any{"jsonrpc": "2.0", "id": request.ID, "result": map[string]any{"protocolVersion": 1, "authMethods": []map[string]string{{"id": "cursor_login"}}, "_meta": map[string]string{"agentVersion": "2026.08.11"}}}); err != nil {
				return err
			}
		case "authenticate":
			if err := write(map[string]any{"jsonrpc": "2.0", "id": request.ID, "result": map[string]any{}}); err != nil {
				return err
			}
		case "session/new":
			if err := write(map[string]any{"jsonrpc": "2.0", "id": request.ID, "result": map[string]string{"sessionId": "4d07f334-88ef-4fe4-a640-421e3ba79921"}}); err != nil {
				return err
			}
		case "session/prompt":
			if toolRequest {
				return write(map[string]any{"jsonrpc": "2.0", "id": 91, "method": "cursor/ask_question", "params": map[string]any{}})
			}
			if err := write(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"update": map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]string{"type": "text", "text": "Evidence-backed answer."}}}}); err != nil {
				return err
			}
			result := map[string]any{"stopReason": "end_turn"}
			if !omitUsage {
				result["usage"] = map[string]int{"inputTokens": 80, "outputTokens": 20}
			}
			return write(map[string]any{"jsonrpc": "2.0", "id": request.ID, "result": result})
		}
	}
	return scanner.Err()
}

func TestExecuteNegotiatesCursorLoginAndEmitsCanonicalOutput(t *testing.T) {
	runner := &fakeInteractiveRunner{}
	events := make([]protocol.CanonicalEvent, 0)
	result, err := New(func() time.Time { return testNow }).Execute(context.Background(), testInvocation(), runner, func(event protocol.CanonicalEvent) error {
		if err := event.Validate(); err != nil {
			t.Fatal(err)
		}
		events = append(events, event)
		return nil
	})
	if err != nil || result.Status != "completed" || result.Output != "Evidence-backed answer." || !result.UsageObserved || result.InputUnits != 80 || result.OutputUnits != 20 {
		t.Fatalf("result=%#v err=%v", result, err)
	}
	if !reflect.DeepEqual(runner.request.Arguments, []string{"acp"}) || runner.request.HomeDir != "/runtime/cursor-home" || runner.request.EgressProfileKey != "model_api" {
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

func TestExecuteSendsExplicitModelAsCursorGlobalFlag(t *testing.T) {
	runner := &fakeInteractiveRunner{}
	invocation := testInvocation()
	invocation.Model = "gpt-5.5-medium"
	result, err := New(func() time.Time { return testNow }).Execute(context.Background(), invocation, runner, func(event protocol.CanonicalEvent) error {
		return event.Validate()
	})
	if err != nil || result.Status != "completed" {
		t.Fatalf("result=%#v err=%v", result, err)
	}
	if !reflect.DeepEqual(runner.request.Arguments, []string{"--model", invocation.Model, "acp"}) {
		t.Fatalf("explicit Cursor model was not sent as a global flag: %#v", runner.request.Arguments)
	}
}

func TestExecuteFailsBeforeOutputWhenObservedUsageExceedsBudget(t *testing.T) {
	invocation := testInvocation()
	invocation.Admission.Routing.MaxOutputUnits = 19
	events := make([]protocol.CanonicalEvent, 0)
	result, err := New(func() time.Time { return testNow }).Execute(context.Background(), invocation, &fakeInteractiveRunner{}, func(event protocol.CanonicalEvent) error {
		events = append(events, event)
		return nil
	})
	if err != nil || result.FailureCode != "runtime_unit_budget_exceeded" || len(events) != 2 || events[1].EventType != "run.failed" {
		t.Fatalf("result=%#v events=%#v err=%v", result, events, err)
	}
}

func TestExecuteAllowsMissingDraftUsageWithoutInventingIt(t *testing.T) {
	runner := &fakeInteractiveRunner{omitUsage: true}
	events := make([]protocol.CanonicalEvent, 0)
	result, err := New(func() time.Time { return testNow }).Execute(context.Background(), testInvocation(), runner, func(event protocol.CanonicalEvent) error { events = append(events, event); return nil })
	if err != nil || result.Status != "completed" || result.UsageObserved || len(events) != 3 || events[1].EventType != "output.produced" || events[2].EventType != "run.completed" {
		t.Fatalf("result=%#v events=%#v err=%v", result, events, err)
	}
}

func TestExecuteRejectsBlockingCursorExtension(t *testing.T) {
	runner := &fakeInteractiveRunner{toolRequest: true}
	result, err := New(func() time.Time { return testNow }).Execute(context.Background(), testInvocation(), runner, func(protocol.CanonicalEvent) error { return nil })
	if err != nil || result.Status != "failed" || result.FailureCode != "cursor_policy_denied" {
		t.Fatalf("result=%#v err=%v", result, err)
	}
}

func TestCompatibleVersionAcceptsFutureVersionsWithBoundedEvidence(t *testing.T) {
	if !compatibleVersion("cursor-agent 2026.08.11") || !compatibleVersion("2026.03.10") || compatibleVersion("2026.04.31") || !compatibleVersion("2027.01.01") || compatibleVersion("cursor development build") {
		t.Fatal("unexpected observed-version result")
	}
}

func testInvocation() Invocation {
	return Invocation{
		Admission: protocol.AdmissionRequest{
			ProtocolVersion: protocol.Version, RunID: "3d07f334-88ef-4fe4-a640-421e3ba79921", IdempotencyKey: "cursor-test", WorkspaceKey: "c9bb966b-1fe9-4304-bd51-404e4fd9a09c",
			Task:    protocol.Task{TaskKey: "fae7db72-e33b-46b9-8f9e-9a0dfdd56661", Attempt: 1, Title: "Investigate", InputContext: "Case facts", ExpectedOutput: "Cited answer"},
			Agent:   protocol.AgentPolicy{RoleKey: "support_investigator", PolicyVersion: 1, Instructions: "Investigate.", AllowedTools: []string{"case_read"}, RuntimeProfileKey: "workspace_default", TimeoutSeconds: 300, MaxSteps: 10, MaxToolCalls: 20, ReviewPolicy: "required"},
			Routing: protocol.RuntimeRouting{MaxInputUnits: 1_000_000, MaxOutputUnits: 1_000_000},
		},
		Executable: "/opt/cursor-agent", WorkingDir: "/work/run", CursorHome: "/runtime/cursor-home", Prompt: "Investigate the case.", EgressProfileKey: "model_api",
	}
}
