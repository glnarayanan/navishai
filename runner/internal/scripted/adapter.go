package scripted

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

type Status string

const (
	Completed      Status = "completed"
	Retryable      Status = "retryable_error"
	TimedOut       Status = "timed_out"
	Canceled       Status = "canceled"
	PolicyDenied   Status = "policy_denied"
	BudgetExceeded Status = "budget_exceeded"
	Malformed      Status = "malformed_output"
)

var ErrAttemptMissing = errors.New("script has no matching attempt")

type Result struct {
	Status Status
	Output string
}

type Adapter struct {
	now func() time.Time
}

func New(now func() time.Time) *Adapter {
	if now == nil {
		now = time.Now
	}
	return &Adapter{now: now}
}

func (adapter *Adapter) Execute(ctx context.Context, request protocol.AdmissionRequest, script Script, emit func(protocol.CanonicalEvent) error) (Result, error) {
	attempt, found := script.attempt(request.Task.Attempt)
	if !found {
		return Result{}, ErrAttemptMissing
	}
	sequence := 2
	emitEvent := func(eventType string, data map[string]any) error {
		event, err := protocol.NewCanonicalEvent(request.RunID, sequence, eventType, adapter.now(), data)
		if err != nil {
			return err
		}
		if err := emit(event); err != nil {
			return fmt.Errorf("emit %s: %w", eventType, err)
		}
		sequence++
		return nil
	}
	if err := emitEvent("run.started", map[string]any{"adapter": "scripted", "scenario": script.Scenario, "attempt": attempt.Number}); err != nil {
		return Result{}, err
	}

	if attempt.DelayMillis > 0 || attempt.Result == "wait" {
		timer := time.NewTimer(time.Duration(attempt.DelayMillis) * time.Millisecond)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			status, eventType := Canceled, "run.canceled"
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				status, eventType = TimedOut, "run.timed_out"
			}
			if err := emitEvent(eventType, map[string]any{"reason": ctx.Err().Error()}); err != nil {
				return Result{}, err
			}
			return Result{Status: status}, nil
		case <-timer.C:
		}
	}
	if attempt.Result == "wait" {
		if err := emitEvent("run.failed", map[string]any{"code": "scripted_wait_elapsed", "retryable": true}); err != nil {
			return Result{}, err
		}
		return Result{Status: Retryable}, nil
	}

	allowed := make(map[string]struct{}, len(request.Agent.AllowedTools))
	for _, tool := range request.Agent.AllowedTools {
		allowed[tool] = struct{}{}
	}
	for _, tool := range attempt.ToolCalls {
		if _, approved := allowed[tool]; !approved {
			if err := emitEvent("run.policy_denied", map[string]any{"code": "tool_not_allowed", "tool": tool}); err != nil {
				return Result{}, err
			}
			return Result{Status: PolicyDenied}, nil
		}
		if err := emitEvent("tool.completed", map[string]any{"tool": tool, "result": "scripted"}); err != nil {
			return Result{}, err
		}
	}

	if attempt.Result == "retryable_error" {
		if err := emitEvent("run.failed", map[string]any{"code": "scripted_retry", "retryable": true}); err != nil {
			return Result{}, err
		}
		return Result{Status: Retryable}, nil
	}

	output, err := decodeOutput(attempt.OutputJSON)
	if err != nil {
		if emitErr := emitEvent("run.failed", map[string]any{"code": "malformed_output", "retryable": false}); emitErr != nil {
			return Result{}, emitErr
		}
		return Result{Status: Malformed}, nil
	}
	if !adapters.WithinUnitBudget(request, attempt.Usage.InputUnits, attempt.Usage.OutputUnits) {
		if err := emitEvent("run.failed", map[string]any{"code": "runtime_unit_budget_exceeded", "retryable": false}); err != nil {
			return Result{}, err
		}
		return Result{Status: BudgetExceeded}, nil
	}
	if err := emitEvent("output.produced", map[string]any{"text": output.Text}); err != nil {
		return Result{}, err
	}
	if err := emitEvent("usage.observed", map[string]any{"input_units": attempt.Usage.InputUnits, "output_units": attempt.Usage.OutputUnits}); err != nil {
		return Result{}, err
	}
	if err := emitEvent("run.completed", map[string]any{"outcome": "completed"}); err != nil {
		return Result{}, err
	}
	return Result{Status: Completed, Output: output.Text}, nil
}

func decodeOutput(raw string) (Output, error) {
	decoder := json.NewDecoder(bytes.NewReader([]byte(raw)))
	decoder.DisallowUnknownFields()
	var output Output
	if err := decoder.Decode(&output); err != nil {
		return Output{}, err
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) || strings.TrimSpace(output.Text) == "" || len(output.Text) > maxOutputBytes {
		return Output{}, ErrInvalidScript
	}
	return output, nil
}
