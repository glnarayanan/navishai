package execution

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/admission"
	"github.com/glnarayanan/navishai/runner/internal/events"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

type recordingSink struct {
	mu                sync.Mutex
	events            []protocol.CanonicalEvent
	loseFirstResponse bool
}

func (sink *recordingSink) Deliver(_ context.Context, _ string, event protocol.CanonicalEvent) error {
	sink.mu.Lock()
	defer sink.mu.Unlock()
	sink.events = append(sink.events, event)
	if sink.loseFirstResponse {
		sink.loseFirstResponse = false
		return events.ErrUnavailable
	}
	return nil
}

func (sink *recordingSink) snapshot() []protocol.CanonicalEvent {
	sink.mu.Lock()
	defer sink.mu.Unlock()
	return append([]protocol.CanonicalEvent(nil), sink.events...)
}

type completingExecutor struct{ now time.Time }

func (executor completingExecutor) Execute(_ context.Context, request protocol.AdmissionRequest, emit func(protocol.CanonicalEvent) error) error {
	started, _ := protocol.NewCanonicalEvent(request.RunID, 2, "run.started", executor.now, map[string]any{
		"adapter": "scripted", "scenario": "dispatcher", "attempt": request.Task.Attempt,
	})
	if err := emit(started); err != nil {
		return err
	}
	completed, _ := protocol.NewCanonicalEvent(request.RunID, 3, "run.completed", executor.now.Add(time.Second), map[string]any{
		"outcome": "completed",
	})
	return emit(completed)
}

func TestDispatcherExecutesDurableAdmissionAndReplaysExactEvent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "runs.json")
	store, request, response := admittedStore(t, path)
	sink := &recordingSink{loseFirstResponse: true}
	dispatcher, err := NewDispatcher(store, sink, completingExecutor{now: response.Event.OccurredAt.Add(time.Second)}, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- dispatcher.Run(ctx) }()

	waitForEvents(t, sink, 4)
	cancel()
	<-done
	events := sink.snapshot()
	if events[0].EventID != events[1].EventID || events[0].Sequence != 1 || events[1].Sequence != 1 {
		t.Fatalf("lost acknowledgement must replay the exact admitted event: %#v", events[:2])
	}
	if events[len(events)-1].EventType != "run.completed" || events[len(events)-1].RunID != request.RunID {
		t.Fatalf("run did not complete: %#v", events)
	}

	reopened, err := admission.OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := reopened.NextEvent(); ok || reopened.IsRunning(request.RunID) {
		t.Fatal("completed run must reopen without pending execution or delivery")
	}
}

func TestDispatcherMarksInterruptedRunFailedWithoutRelaunch(t *testing.T) {
	path := filepath.Join(t.TempDir(), "runs.json")
	store, request, response := admittedStoreWithBoundary(t, path, protocol.ExecutionModeBounded, protocol.IsolationPolicyStrongRequired)
	pending, _ := store.NextEvent()
	if err := store.MarkDelivered(request.RunID, pending.Event.EventID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Claim(request.RunID); err != nil {
		t.Fatal(err)
	}
	started, _ := protocol.NewCanonicalEvent(request.RunID, 2, "run.started", response.Event.OccurredAt.Add(time.Second), map[string]any{
		"adapter": "scripted", "scenario": "before-crash", "attempt": 1,
	})
	if err := store.AppendEvent(request.RunID, started); err != nil {
		t.Fatal(err)
	}

	reopened, err := admission.OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	sink := &recordingSink{}
	executor := &countingExecutor{}
	dispatcher, _ := NewDispatcher(reopened, sink, executor, func() time.Time { return response.Event.OccurredAt.Add(2 * time.Second) })
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- dispatcher.Run(ctx) }()
	waitForEvents(t, sink, 2)
	cancel()
	<-done
	if executor.calls != 0 {
		t.Fatal("interrupted run must not relaunch its adapter")
	}
	events := sink.snapshot()
	if events[0].EventID != started.EventID || events[1].EventType != "run.failed" ||
		events[1].Data["code"] != "runner_interrupted" || events[1].Data["retryable"] != true {
		t.Fatalf("unexpected recovery events: %#v", events)
	}
}

func TestDispatcherMarksInterruptedHostTrustedRunOrphanedAndNonRetryable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "runs.json")
	store, request, response := admittedStoreWithBoundary(t, path, protocol.ExecutionModeHostTrusted, protocol.IsolationPolicyHostTrustedAllowed)
	pending, _ := store.NextEvent()
	if err := store.MarkDelivered(request.RunID, pending.Event.EventID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Claim(request.RunID); err != nil {
		t.Fatal(err)
	}
	started, _ := protocol.NewCanonicalEvent(request.RunID, 2, "run.started", response.Event.OccurredAt.Add(time.Second), map[string]any{
		"adapter": "scripted", "scenario": "before-crash", "attempt": 1,
	})
	if err := store.AppendEvent(request.RunID, started); err != nil {
		t.Fatal(err)
	}

	if err := (&Dispatcher{store: store, now: func() time.Time { return response.Event.OccurredAt.Add(2 * time.Second) }}).recoverInterrupted(); err != nil {
		t.Fatal(err)
	}
	pending, ok := store.NextEvent()
	if !ok || pending.Event.EventType != "run.started" {
		t.Fatalf("unexpected started event after recovery: %#v %t", pending, ok)
	}
	if err := store.MarkDelivered(request.RunID, pending.Event.EventID); err != nil {
		t.Fatal(err)
	}
	pending, ok = store.NextEvent()
	if !ok || pending.Event.EventType != "run.failed" || pending.Event.Data["code"] != hostTrustedInterruptedFailureCode || pending.Event.Data["retryable"] != false {
		t.Fatalf("host-trusted interruption was not orphaned and non-retryable: %#v %t", pending, ok)
	}
	if store.IsRunning(request.RunID) {
		t.Fatal("host-trusted interruption remained runnable after recovery")
	}
}

type countingExecutor struct{ calls int }

func (executor *countingExecutor) Execute(context.Context, protocol.AdmissionRequest, func(protocol.CanonicalEvent) error) error {
	executor.calls++
	return errors.New("unexpected execution")
}

func admittedStore(t *testing.T, path string) (*admission.Store, protocol.AdmissionRequest, protocol.AdmissionResponse) {
	return admittedStoreWithBoundary(t, path, protocol.ExecutionModeBounded, protocol.IsolationPolicyStrongRequired)
}

func admittedStoreWithBoundary(t *testing.T, path, executionMode, isolationPolicy string) (*admission.Store, protocol.AdmissionRequest, protocol.AdmissionResponse) {
	t.Helper()
	body, err := os.ReadFile(filepath.Join("..", "..", "..", "test", "fixtures", "files", "runner_protocol", "v2", "admission_request.json"))
	if err != nil {
		t.Fatal(err)
	}
	request, err := protocol.DecodeAdmissionBytes(body)
	if err != nil {
		t.Fatal(err)
	}
	request.Routing.ExecutionMode = executionMode
	request.Routing.IsolationPolicy = isolationPolicy
	at := time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)
	event, _ := protocol.NewCanonicalEvent(request.RunID, 1, "run.admitted", at, map[string]any{
		"workspace_key": request.WorkspaceKey, "task_key": request.Task.TaskKey, "attempt": request.Task.Attempt,
	})
	response := protocol.AdmissionResponse{ProtocolVersion: protocol.AdmissionVersion, RunID: request.RunID, Status: "accepted", Event: event}
	store, err := admission.OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.Admit(request, protocol.Digest(body), response); err != nil {
		t.Fatal(err)
	}
	return store, request, response
}

func waitForEvents(t *testing.T, sink *recordingSink, count int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if len(sink.snapshot()) >= count {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %d events; got %#v", count, sink.snapshot())
}
