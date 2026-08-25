package execution

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/admission"
	"github.com/glnarayanan/navishai/runner/internal/events"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

const retryDelay = time.Second

type EventSink interface {
	Deliver(context.Context, string, protocol.CanonicalEvent) error
}

type Executor interface {
	Execute(context.Context, protocol.AdmissionRequest, func(protocol.CanonicalEvent) error) error
}

type Dispatcher struct {
	store    *admission.Store
	sink     EventSink
	executor Executor
	now      func() time.Time
}

func NewDispatcher(store *admission.Store, sink EventSink, executor Executor, now func() time.Time) (*Dispatcher, error) {
	if store == nil || sink == nil || executor == nil {
		return nil, errors.New("dispatcher dependencies are required")
	}
	if now == nil {
		now = time.Now
	}
	return &Dispatcher{store: store, sink: sink, executor: executor, now: now}, nil
}

func (dispatcher *Dispatcher) Run(ctx context.Context) error {
	if err := dispatcher.recoverInterrupted(); err != nil {
		return err
	}
	for {
		if err := dispatcher.deliverPending(ctx); err != nil {
			return err
		}
		request, ok := dispatcher.store.NextQueued()
		if ok {
			if err := dispatcher.execute(ctx, request.RunID); err != nil {
				return err
			}
			continue
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
}

func (dispatcher *Dispatcher) execute(ctx context.Context, runID string) error {
	request, err := dispatcher.store.Claim(runID)
	if err != nil {
		return err
	}
	emit := func(event protocol.CanonicalEvent) error {
		if err := dispatcher.store.AppendEvent(runID, event); err != nil {
			return err
		}
		return dispatcher.deliverPending(ctx)
	}
	err = dispatcher.executor.Execute(ctx, request, emit)
	if !dispatcher.store.IsRunning(runID) {
		return dispatcher.deliverPending(ctx)
	}
	code, retryable := "runner_incomplete", true
	if err != nil {
		code = "runner_execution_failed"
	}
	if errors.Is(err, ErrPolicyDenied) {
		code, retryable = "runtime_policy_changed", false
	}
	if appendErr := dispatcher.appendFailure(request, code, retryable); appendErr != nil {
		return errors.Join(err, appendErr)
	}
	if deliverErr := dispatcher.deliverPending(ctx); deliverErr != nil {
		return errors.Join(err, deliverErr)
	}
	return nil
}

func (dispatcher *Dispatcher) recoverInterrupted() error {
	for _, request := range dispatcher.store.Running() {
		if err := dispatcher.appendFailure(request, "runner_interrupted", true); err != nil {
			return err
		}
	}
	return nil
}

func (dispatcher *Dispatcher) appendFailure(request protocol.AdmissionRequest, code string, retryable bool) error {
	sequence, err := dispatcher.store.LastSequence(request.RunID)
	if err != nil {
		return err
	}
	lastOccurredAt, err := dispatcher.store.LastOccurredAt(request.RunID)
	if err != nil {
		return err
	}
	at := dispatcher.now().UTC()
	if at.Before(lastOccurredAt) {
		at = lastOccurredAt
	}
	if sequence == 1 {
		started, eventErr := protocol.NewCanonicalEvent(request.RunID, 2, "run.started", at, map[string]any{
			"adapter": request.Routing.AdapterKey, "scenario": "runner", "attempt": request.Task.Attempt,
		})
		if eventErr != nil {
			return eventErr
		}
		if err := dispatcher.store.AppendEvent(request.RunID, started); err != nil {
			return err
		}
		sequence = 2
		at = at.Add(time.Microsecond)
	}
	failed, err := protocol.NewCanonicalEvent(request.RunID, sequence+1, "run.failed", at, map[string]any{
		"code": code, "retryable": retryable,
	})
	if err != nil {
		return err
	}
	return dispatcher.store.AppendEvent(request.RunID, failed)
}

func (dispatcher *Dispatcher) deliverPending(ctx context.Context) error {
	for {
		pending, ok := dispatcher.store.NextEvent()
		if !ok {
			return nil
		}
		err := dispatcher.sink.Deliver(ctx, pending.WorkspaceKey, pending.Event)
		if err == nil {
			if err := dispatcher.store.MarkDelivered(pending.RunID, pending.Event.EventID); err != nil {
				return err
			}
			continue
		}
		if !errors.Is(err, events.ErrUnavailable) {
			return fmt.Errorf("deliver run %s event %d: %w", pending.RunID, pending.Event.Sequence, err)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(retryDelay):
		}
	}
}
