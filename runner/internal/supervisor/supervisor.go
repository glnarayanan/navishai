//go:build linux && amd64

package supervisor

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	maxArguments      = 100
	maxArgumentBytes  = 16 * 1024
	maxInputBytes     = 256 * 1024
	maxCredentialKeys = 32
)

var (
	ErrInvalidRequest = errors.New("invalid supervised process request")
	ErrOutputLimit    = errors.New("process output limit exceeded")
	credentialPattern = regexp.MustCompile(`^[A-Z][A-Z0-9_]{0,63}$`)
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
	AllowedExecutableRoots []string
	AllowedWorkingRoots    []string
	RuntimeReadRoots       []string
	Limits                 Limits
}

type Request struct {
	Executable  string
	Arguments   []string
	WorkingDir  string
	Input       []byte
	Credentials map[string]string
}

type Result struct {
	ExitCode       int
	StandardOutput string
	StandardError  string
	TimedOut       bool
	Canceled       bool
	OutputExceeded bool
}

type Supervisor struct {
	helperPath       string
	executableRoots  []string
	workingRoots     []string
	runtimeReadRoots []string
	limits           Limits
}

func New(config Config) (*Supervisor, error) {
	helper, err := approvedExecutable(config.HelperPath)
	if err != nil || config.Limits.WallTime <= 0 || config.Limits.CPUSeconds < 1 ||
		config.Limits.MemoryBytes < 32*1024*1024 || config.Limits.OpenFiles < 3 ||
		config.Limits.Processes < 1 || config.Limits.OutputBytes < 1 || config.Limits.KillGrace < 0 {
		return nil, ErrInvalidRequest
	}
	executableRoots, err := realRoots(config.AllowedExecutableRoots)
	if err != nil {
		return nil, err
	}
	workingRoots, err := realRoots(config.AllowedWorkingRoots)
	if err != nil {
		return nil, err
	}
	runtimeReadRoots, err := realRoots(config.RuntimeReadRoots)
	if err != nil {
		return nil, err
	}
	return &Supervisor{helperPath: helper, executableRoots: executableRoots, workingRoots: workingRoots, runtimeReadRoots: runtimeReadRoots, limits: config.Limits}, nil
}

func approvedExecutable(path string) (string, error) {
	real, err := filepath.EvalSymlinks(path)
	if err != nil || !filepath.IsAbs(real) {
		return "", ErrInvalidRequest
	}
	info, err := os.Stat(real)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 || info.Mode()&(os.ModeSetuid|os.ModeSetgid) != 0 {
		return "", ErrInvalidRequest
	}
	return filepath.Clean(real), nil
}

func (supervisor *Supervisor) Run(ctx context.Context, request Request) (Result, error) {
	executable, err := approvedFile(request.Executable, supervisor.executableRoots)
	if err != nil {
		return Result{}, err
	}
	workingDir, err := approvedDirectory(request.WorkingDir, supervisor.workingRoots)
	if err != nil || len(request.Arguments) > maxArguments || len(request.Input) > maxInputBytes || len(request.Credentials) > maxCredentialKeys {
		return Result{}, ErrInvalidRequest
	}
	argumentBytes := 0
	for _, argument := range request.Arguments {
		if strings.ContainsRune(argument, 0) {
			return Result{}, ErrInvalidRequest
		}
		argumentBytes += len(argument)
	}
	if argumentBytes > maxArgumentBytes {
		return Result{}, ErrInvalidRequest
	}
	environment := []string{
		"HOME=" + workingDir, "LANG=C.UTF-8", "NAVISHAI_DENY_NETWORK=1",
		"NAVISHAI_LIMIT_CPU_SECONDS=" + strconv.FormatUint(supervisor.limits.CPUSeconds, 10),
		"NAVISHAI_LIMIT_MEMORY_BYTES=" + strconv.FormatUint(supervisor.limits.MemoryBytes, 10),
		"NAVISHAI_LIMIT_OPEN_FILES=" + strconv.FormatUint(supervisor.limits.OpenFiles, 10),
		"NAVISHAI_LIMIT_PROCESSES=" + strconv.FormatUint(supervisor.limits.Processes, 10),
	}
	readRoots, err := json.Marshal(append(supervisor.runtimeReadRoots, supervisor.executableRoots...))
	if err != nil {
		return Result{}, ErrInvalidRequest
	}
	writeRoots, err := json.Marshal([]string{workingDir})
	if err != nil {
		return Result{}, ErrInvalidRequest
	}
	environment = append(environment, "NAVISHAI_EXEC_READ_ROOTS="+string(readRoots), "NAVISHAI_EXEC_WRITE_ROOTS="+string(writeRoots))
	for key, value := range request.Credentials {
		if !credentialPattern.MatchString(key) || strings.HasPrefix(key, "NAVISHAI_") || len(value) > 16*1024 || strings.ContainsRune(value, 0) {
			return Result{}, ErrInvalidRequest
		}
		environment = append(environment, key+"="+value)
	}

	runContext, cancel := context.WithTimeout(ctx, supervisor.limits.WallTime)
	defer cancel()
	command := exec.Command(supervisor.helperPath, append([]string{executable}, request.Arguments...)...)
	command.Dir = workingDir
	command.Env = environment
	command.Stdin = bytes.NewReader(request.Input)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGKILL}
	output := newBoundedOutput(supervisor.limits.OutputBytes)
	output.onOverflow = func() {
		if command.Process != nil {
			_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		}
	}
	command.Stdout = output
	command.Stderr = output.stderr()
	if err := command.Start(); err != nil {
		return Result{}, fmt.Errorf("start supervised process: %w", err)
	}
	waited := make(chan error, 1)
	go func() { waited <- command.Wait() }()
	var waitErr error
	timedOut, canceled := false, false
	select {
	case waitErr = <-waited:
	case <-runContext.Done():
		timedOut = errors.Is(runContext.Err(), context.DeadlineExceeded) && ctx.Err() == nil
		canceled = !timedOut
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGTERM)
		grace := time.NewTimer(supervisor.limits.KillGrace)
		select {
		case waitErr = <-waited:
			if !grace.Stop() {
				<-grace.C
			}
		case <-grace.C:
			_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
			waitErr = <-waited
		}
	}
	// The approved process may exit after starting descendants. Clear the whole
	// process group before returning so no run can outlive its durable attempt.
	_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)

	result := Result{
		ExitCode: command.ProcessState.ExitCode(), StandardOutput: output.stdoutString(),
		StandardError: output.stderrString(), TimedOut: timedOut, Canceled: canceled,
		OutputExceeded: output.exceeded(),
	}
	if result.OutputExceeded {
		return result, ErrOutputLimit
	}
	if waitErr != nil && !timedOut && !canceled {
		var exitError *exec.ExitError
		if !errors.As(waitErr, &exitError) {
			return result, waitErr
		}
	}
	return result, nil
}

func realRoots(values []string) ([]string, error) {
	if len(values) == 0 {
		return nil, ErrInvalidRequest
	}
	result := make([]string, 0, len(values))
	for _, value := range values {
		path, err := filepath.EvalSymlinks(value)
		if err != nil || !filepath.IsAbs(path) {
			return nil, ErrInvalidRequest
		}
		info, err := os.Stat(path)
		if err != nil || !info.IsDir() {
			return nil, ErrInvalidRequest
		}
		result = append(result, filepath.Clean(path))
	}
	return result, nil
}

func approvedFile(path string, roots []string) (string, error) {
	real, err := filepath.EvalSymlinks(path)
	if err != nil || !filepath.IsAbs(real) || !withinRoots(real, roots) {
		return "", ErrInvalidRequest
	}
	return approvedExecutable(real)
}

func approvedDirectory(path string, roots []string) (string, error) {
	real, err := filepath.EvalSymlinks(path)
	if err != nil || !filepath.IsAbs(real) || !withinRoots(real, roots) {
		return "", ErrInvalidRequest
	}
	info, err := os.Stat(real)
	if err != nil || !info.IsDir() {
		return "", ErrInvalidRequest
	}
	return filepath.Clean(real), nil
}

func withinRoots(path string, roots []string) bool {
	for _, root := range roots {
		relative, err := filepath.Rel(root, path)
		if err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

type boundedOutput struct {
	mu           sync.Mutex
	remaining    int
	stdout       bytes.Buffer
	stderrBuffer bytes.Buffer
	overflow     bool
	onOverflow   func()
}

func newBoundedOutput(limit int) *boundedOutput {
	return &boundedOutput{remaining: limit}
}

func (output *boundedOutput) stderr() io.Writer {
	return &boundedOutputStream{output: output, stderr: true}
}

func (output *boundedOutput) Write(data []byte) (int, error) {
	return output.write(data, false)
}

func (output *boundedOutput) write(data []byte, stderr bool) (int, error) {
	output.mu.Lock()
	defer output.mu.Unlock()
	if len(data) > output.remaining {
		kept := data[:max(0, output.remaining)]
		if stderr {
			_, _ = output.stderrBuffer.Write(kept)
		} else {
			_, _ = output.stdout.Write(kept)
		}
		output.remaining = 0
		output.overflow = true
		if output.onOverflow != nil {
			go output.onOverflow()
		}
		return len(kept), ErrOutputLimit
	}
	output.remaining -= len(data)
	if stderr {
		return output.stderrBuffer.Write(data)
	}
	return output.stdout.Write(data)
}

func (output *boundedOutput) stdoutString() string {
	output.mu.Lock()
	defer output.mu.Unlock()
	return output.stdout.String()
}
func (output *boundedOutput) stderrString() string {
	output.mu.Lock()
	defer output.mu.Unlock()
	return output.stderrBuffer.String()
}
func (output *boundedOutput) exceeded() bool {
	output.mu.Lock()
	defer output.mu.Unlock()
	return output.overflow
}

type boundedOutputStream struct {
	output *boundedOutput
	stderr bool
}

func (stream *boundedOutputStream) Write(data []byte) (int, error) {
	return stream.output.write(data, stream.stderr)
}
