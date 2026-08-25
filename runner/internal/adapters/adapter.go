package adapters

import (
	"context"

	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

type ProcessRunner interface {
	Run(context.Context, supervisor.Request) (supervisor.Result, error)
}
