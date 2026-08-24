package adapters

import (
	"context"
	"io"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

type ProcessRunner interface {
	Run(context.Context, supervisor.Request) (supervisor.Result, error)
}

func WithinUnitBudget(admission protocol.AdmissionRequest, inputUnits, outputUnits int) bool {
	return inputUnits >= 0 && outputUnits >= 0 && inputUnits <= admission.Routing.MaxInputUnits && outputUnits <= admission.Routing.MaxOutputUnits
}

type InteractiveProcessRunner interface {
	Interact(context.Context, supervisor.Request, func(context.Context, io.ReadWriter) error) (supervisor.Result, error)
}
