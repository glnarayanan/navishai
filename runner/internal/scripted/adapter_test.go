package scripted

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

var scriptedNow = time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)

func TestSuccessfulScriptProducesCanonicalEvents(t *testing.T) {
	request := admissionRequest(t)
	result, events, err := execute(t, context.Background(), request, "success.json")
	if err != nil {
		t.Fatal(err)
	}
	if result.Status != Completed || result.Output == "" {
		t.Fatalf("unexpected result: %#v", result)
	}
	expected := []string{"run.started", "tool.completed", "tool.completed", "output.produced", "usage.observed", "run.completed"}
	assertEventTypes(t, events, expected)
	for index, event := range events {
		if event.ProtocolVersion != protocol.Version || event.RunID != request.RunID || event.Sequence != index+2 || event.EventID == "" || event.Validate() != nil {
			t.Fatalf("event is not canonical: %#v", event)
		}
	}
}

func TestUsageBudgetFailsBeforeOutput(t *testing.T) {
	request := admissionRequest(t)
	request.Routing.MaxInputUnits = 119
	result, events, err := execute(t, context.Background(), request, "success.json")
	if err != nil || result.Status != BudgetExceeded {
		t.Fatalf("result=%#v err=%v", result, err)
	}
	assertEventTypes(t, events, []string{"run.started", "tool.completed", "tool.completed", "run.failed"})
}

func TestRetryFixtureFailsThenSucceeds(t *testing.T) {
	request := admissionRequest(t)
	first, firstEvents, err := execute(t, context.Background(), request, "retry.json")
	if err != nil || first.Status != Retryable {
		t.Fatalf("unexpected first attempt: result=%#v err=%v", first, err)
	}
	assertEventTypes(t, firstEvents, []string{"run.started", "run.failed"})

	request.Task.Attempt = 2
	second, secondEvents, err := execute(t, context.Background(), request, "retry.json")
	if err != nil || second.Status != Completed {
		t.Fatalf("unexpected second attempt: result=%#v err=%v", second, err)
	}
	assertEventTypes(t, secondEvents, []string{"run.started", "tool.completed", "output.produced", "usage.observed", "run.completed"})
}

func TestTimeoutAndCancellationAreTerminal(t *testing.T) {
	request := admissionRequest(t)
	timeoutContext, stop := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer stop()
	timedOut, timeoutEvents, err := execute(t, timeoutContext, request, "timeout.json")
	if err != nil || timedOut.Status != TimedOut {
		t.Fatalf("unexpected timeout: result=%#v err=%v", timedOut, err)
	}
	assertEventTypes(t, timeoutEvents, []string{"run.started", "run.timed_out"})

	cancelContext, cancel := context.WithCancel(context.Background())
	cancel()
	canceled, cancelEvents, err := execute(t, cancelContext, request, "cancellation.json")
	if err != nil || canceled.Status != Canceled {
		t.Fatalf("unexpected cancellation: result=%#v err=%v", canceled, err)
	}
	assertEventTypes(t, cancelEvents, []string{"run.started", "run.canceled"})
}

func TestMalformedOutputAndPolicyDenialFailClosed(t *testing.T) {
	request := admissionRequest(t)
	malformed, malformedEvents, err := execute(t, context.Background(), request, "malformed_output.json")
	if err != nil || malformed.Status != Malformed || malformed.Output != "" {
		t.Fatalf("unexpected malformed result: result=%#v err=%v", malformed, err)
	}
	assertEventTypes(t, malformedEvents, []string{"run.started", "run.failed"})

	denied, deniedEvents, err := execute(t, context.Background(), request, "policy_denial.json")
	if err != nil || denied.Status != PolicyDenied {
		t.Fatalf("unexpected policy result: result=%#v err=%v", denied, err)
	}
	assertEventTypes(t, deniedEvents, []string{"run.started", "run.policy_denied"})
}

func TestFixtureAndEmitterFailuresStopExecution(t *testing.T) {
	if _, err := Decode(strings.NewReader(`{"scenario":"x","attempts":[],"unknown":true}`)); !errors.Is(err, ErrInvalidScript) {
		t.Fatalf("expected strict fixture rejection, got %v", err)
	}
	if _, err := Decode(strings.NewReader(strings.Repeat("x", maxFixtureBytes+1))); !errors.Is(err, ErrInvalidScript) {
		t.Fatalf("expected bounded fixture rejection, got %v", err)
	}

	request := admissionRequest(t)
	script := loadScript(t, "success.json")
	expected := errors.New("ledger unavailable")
	_, err := New(func() time.Time { return scriptedNow }).Execute(context.Background(), request, script, func(protocol.CanonicalEvent) error {
		return expected
	})
	if !errors.Is(err, expected) {
		t.Fatalf("expected emitter error, got %v", err)
	}
}

func execute(t *testing.T, ctx context.Context, request protocol.AdmissionRequest, fixture string) (Result, []protocol.CanonicalEvent, error) {
	t.Helper()
	events := make([]protocol.CanonicalEvent, 0)
	result, err := New(func() time.Time { return scriptedNow }).Execute(ctx, request, loadScript(t, fixture), func(event protocol.CanonicalEvent) error {
		events = append(events, event)
		return nil
	})
	return result, events, err
}

func admissionRequest(t *testing.T) protocol.AdmissionRequest {
	t.Helper()
	path := filepath.Join("..", "..", "..", "test", "fixtures", "files", "runner_protocol", "v2", "admission_request.json")
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	request, err := protocol.DecodeAdmissionBytes(body)
	if err != nil {
		t.Fatal(err)
	}
	return request
}

func loadScript(t *testing.T, name string) Script {
	t.Helper()
	script, err := Load(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return script
}

func assertEventTypes(t *testing.T, events []protocol.CanonicalEvent, expected []string) {
	t.Helper()
	if len(events) != len(expected) {
		t.Fatalf("expected %d events, got %d: %#v", len(expected), len(events), events)
	}
	for index, eventType := range expected {
		if events[index].EventType != eventType {
			t.Fatalf("event %d: expected %s, got %s", index, eventType, events[index].EventType)
		}
	}
}
