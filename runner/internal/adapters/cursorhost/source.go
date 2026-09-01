package cursorhost

import (
	"context"
	"errors"
	"io"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters"
	"github.com/glnarayanan/navishai/runner/internal/adapters/cursor"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

var (
	ErrUnsupportedPlatform = errors.New("Cursor host-trusted execution requires macOS")
	ErrPolicyDenied        = errors.New("Cursor host-trusted execution policy denied the request")
)

type Runner interface {
	adapters.InteractiveProcessRunner
	Run(context.Context, supervisor.Request) (supervisor.Result, error)
	InteractSession(context.Context, supervisor.Request, func(context.Context, io.ReadWriter, adapters.SessionRegistrar) error) (supervisor.Result, error)
}

type Source struct {
	runner Runner
	now    func() time.Time
}

func New(now func() time.Time) *Source {
	if now == nil {
		now = time.Now
	}
	return &Source{runner: newRunner(), now: now}
}

// NewWithRunner is a narrow test seam. Production construction uses New so
// the build-tagged platform implementation remains the only source of a
// supported host-trusted runner.
func NewWithRunner(runner Runner, now func() time.Time) *Source {
	if now == nil {
		now = time.Now
	}
	return &Source{runner: runner, now: now}
}

func (source *Source) Supported() bool {
	return source != nil && source.runner != nil && platformSupported()
}

func (source *Source) Execute(ctx context.Context, invocation cursor.Invocation, emit func(protocol.CanonicalEvent) error) (cursor.Result, error) {
	if !source.Supported() {
		return cursor.Result{}, ErrUnsupportedPlatform
	}
	if invocation.Admission.Routing.AdapterKey != cursor.AdapterKey ||
		invocation.Admission.Routing.ExecutionMode != protocol.ExecutionModeHostTrusted ||
		invocation.Admission.Routing.IsolationPolicy != protocol.IsolationPolicyHostTrustedAllowed {
		return cursor.Result{}, ErrPolicyDenied
	}
	return cursor.New(source.now).Execute(ctx, invocation, source.runner, emit)
}

func (source *Source) DiscoverModels(ctx context.Context, executable, workingDir, homeDir string) ([]adapters.ModelOption, error) {
	if !source.Supported() {
		return nil, ErrUnsupportedPlatform
	}
	if ctx == nil {
		ctx = context.Background()
	}
	spec := cursor.ModelDiscovery()
	result, err := source.runner.Run(ctx, supervisor.Request{
		Executable: executable, Arguments: append([]string(nil), spec.Arguments...),
		WorkingDir: workingDir, HomeDir: homeDir,
	})
	if err != nil || result.TimedOut || result.Canceled || result.OutputExceeded || result.ExitCode != 0 {
		return nil, errors.New("Cursor model discovery failed")
	}
	if len(result.StandardOutput) == 0 || len(result.StandardOutput) > adapters.MaxModelDiscoveryOutputBytes {
		return nil, errors.New("Cursor model discovery output exceeded its limit")
	}
	return spec.Parse([]byte(result.StandardOutput))
}
