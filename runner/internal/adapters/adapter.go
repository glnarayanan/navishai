package adapters

import (
	"context"
	"io"

	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

type ProcessRunner interface {
	Run(context.Context, supervisor.Request) (supervisor.Result, error)
}

type InteractiveProcessRunner interface {
	Interact(context.Context, supervisor.Request, func(context.Context, io.ReadWriter) error) (supervisor.Result, error)
}
