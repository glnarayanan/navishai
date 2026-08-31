//go:build !linux || !amd64

package supervisor

import (
	"context"
	"errors"
	"io"
	"time"
)

var (
	ErrInvalidRequest      = errors.New("invalid supervised process request")
	ErrOutputLimit         = errors.New("process output limit exceeded")
	ErrUnsupportedPlatform = errors.New("supervised process execution requires linux on amd64")
)

type Limits struct {
	WallTime    time.Duration
	CPUSeconds  uint64
	MemoryBytes uint64
	OpenFiles   uint64
	Processes   uint64
	OutputBytes int
	KillGrace   time.Duration
}

type Config struct {
	HelperPath             string
	NamespaceLauncherPath  string
	AllowedExecutableRoots []string
	ApprovedExecutables    []string
	AllowedWorkingRoots    []string
	AllowedHomeRoots       []string
	RuntimeReadRoots       []string
	EgressProfiles         []EgressProfile
	Limits                 Limits
}

type EgressProfile struct {
	Key                  string
	Executable           string
	UserNamespacePath    string
	NetworkNamespacePath string
	Environment          map[string]string
}

type Request struct {
	Executable       string
	Arguments        []string
	WorkingDir       string
	HomeDir          string
	Input            []byte
	Credentials      map[string]string
	EgressProfileKey string
}

type Result struct {
	ExitCode       int
	StandardOutput string
	StandardError  string
	TimedOut       bool
	Canceled       bool
	OutputExceeded bool
}

type Supervisor struct{}

// Supported reports whether this build can enforce the Linux supervisor
// boundary required for subscription CLI execution.
func Supported() bool { return false }

func New(Config) (*Supervisor, error) {
	return &Supervisor{}, nil
}

func (*Supervisor) Run(context.Context, Request) (Result, error) {
	return Result{}, ErrUnsupportedPlatform
}

func (*Supervisor) Interact(context.Context, Request, func(context.Context, io.ReadWriter) error) (Result, error) {
	return Result{}, ErrUnsupportedPlatform
}
