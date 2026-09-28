package adapters

import (
	"context"
	"fmt"
	"io"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

type ProcessRunner interface {
	Run(context.Context, supervisor.Request) (supervisor.Result, error)
}

// EventEmitter starts after admission (sequence 1) and advances only after delivery.
func EventEmitter(runID string, now func() time.Time, emit func(protocol.CanonicalEvent) error) func(string, map[string]any) error {
	sequence := 2
	return func(eventType string, data map[string]any) error {
		event, err := protocol.NewCanonicalEvent(runID, sequence, eventType, now(), data)
		if err != nil {
			return err
		}
		if err := emit(event); err != nil {
			return fmt.Errorf("emit %s: %w", eventType, err)
		}
		sequence++
		return nil
	}
}

func WithinUnitBudget(admission protocol.AdmissionRequest, inputUnits, outputUnits int) bool {
	return inputUnits >= 0 && outputUnits >= 0 && inputUnits <= admission.Routing.MaxInputUnits && outputUnits <= admission.Routing.MaxOutputUnits
}

type InteractiveProcessRunner interface {
	Interact(context.Context, supervisor.Request, func(context.Context, io.ReadWriter) error) (supervisor.Result, error)
}

// SessionRegistrar lets an interactive source retain the protocol session it
// negotiated before cancellation. The runner owns the exact child lifecycle;
// the adapter only supplies the session identifier needed for an in-band
// cancellation request.
type SessionRegistrar func(string)

type InteractiveProcessSessionRunner interface {
	InteractSession(context.Context, supervisor.Request, func(context.Context, io.ReadWriter, SessionRegistrar) error) (supervisor.Result, error)
}
