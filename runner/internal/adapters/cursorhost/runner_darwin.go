//go:build darwin

package cursorhost

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/glnarayanan/navishai/runner/internal/adapters"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

const (
	hostChildGrace              = 2 * time.Second
	hostCancelWriteTimeout      = 250 * time.Millisecond
	hostInteractionWriteTimeout = 250 * time.Millisecond
	hostInteractionOutputLimit  = 256 * 1024
	hostDiscoveryOutputLimit    = adapters.MaxModelDiscoveryOutputBytes
	hostErrorOutputLimit        = 64 * 1024
	hostCodexInputLimit         = 128 * 1024
)

var codexExecutionPrefix = [...]string{
	"exec", "--json", "--color", "never", "--sandbox", "read-only", "--ephemeral",
	"--ignore-user-config", "--ignore-rules", "-c", `approval_policy="never"`,
	"-c", `web_search="disabled"`,
}

var errInvalidHostRequest = errors.New("invalid host-trusted process request")

type hostRequestKind uint8

const (
	hostCursorDiscovery hostRequestKind = iota
	hostCursorInteractive
	hostCodex
)

type darwinRunner struct {
	grace time.Duration
}

func platformSupported() bool { return true }

func newRunner() Runner { return &darwinRunner{grace: hostChildGrace} }

func (runner *darwinRunner) Interact(ctx context.Context, request supervisor.Request, interact func(context.Context, io.ReadWriter) error) (supervisor.Result, error) {
	return runner.InteractSession(ctx, request, func(sessionContext context.Context, stream io.ReadWriter, _ adapters.SessionRegistrar) error {
		return interact(sessionContext, stream)
	})
}

func (runner *darwinRunner) Run(ctx context.Context, request supervisor.Request) (supervisor.Result, error) {
	if !validHostRequest(request, false) || !validDiscoveryArguments(request.Arguments) {
		return supervisor.Result{}, errInvalidHostRequest
	}
	return runner.run(ctx, request, hostDiscoveryOutputLimit, hostCursorDiscovery)
}

func (runner *darwinRunner) RunCodex(ctx context.Context, request supervisor.Request) (supervisor.Result, error) {
	if !validCodexHostRequest(request) {
		return supervisor.Result{}, errInvalidHostRequest
	}
	return runner.run(ctx, request, hostInteractionOutputLimit, hostCodex)
}

func (runner *darwinRunner) run(ctx context.Context, request supervisor.Request, outputLimit int, kind hostRequestKind) (supervisor.Result, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	child, err := startExactChild(request, kind)
	if err != nil {
		return supervisor.Result{}, err
	}
	stdout := newBoundedCapture(outputLimit, child.markOutputExceeded)
	stderr := newBoundedCapture(hostErrorOutputLimit, child.markOutputExceeded)
	stdoutDone := make(chan struct{})
	stderrDone := make(chan struct{})
	go drain(child.stdout, stdout, stdoutDone)
	go drain(child.stderr, stderr, stderrDone)
	var inputErr error
	if len(request.Input) > 0 {
		inputErr = child.input.WriteBounded(request.Input, hostInteractionWriteTimeout)
	}
	_ = child.input.Close()
	if inputErr != nil {
		child.stopAfterClose(runner.grace)
	}

	timedOut, canceled := false, false
	select {
	case <-child.waitDone:
	case <-ctx.Done():
		timedOut, canceled = contextOutcome(ctx)
		child.stopAfterClose(runner.grace)
	case <-stdout.overflowedChan():
		child.stopAfterClose(runner.grace)
	case <-stderr.overflowedChan():
		child.stopAfterClose(runner.grace)
	}
	child.stopAfterClose(runner.grace)
	<-child.waitDone
	<-stdoutDone
	<-stderrDone
	result := child.result(timedOut, canceled, stdout.String(), stderr.String())
	if result.OutputExceeded {
		return result, supervisor.ErrOutputLimit
	}
	if inputErr != nil && !timedOut && !canceled {
		return result, inputErr
	}
	if waitErr := child.waitError(); waitErr != nil && !timedOut && !canceled {
		var exitError *exec.ExitError
		if !errors.As(waitErr, &exitError) {
			return result, waitErr
		}
	}
	return result, nil
}

func (runner *darwinRunner) InteractSession(ctx context.Context, request supervisor.Request, interact func(context.Context, io.ReadWriter, adapters.SessionRegistrar) error) (supervisor.Result, error) {
	if interact == nil || !validHostRequest(request, true) || !validInteractiveArguments(request.Arguments) {
		return supervisor.Result{}, errInvalidHostRequest
	}
	if ctx == nil {
		ctx = context.Background()
	}
	child, err := startExactChild(request, hostCursorInteractive)
	if err != nil {
		return supervisor.Result{}, err
	}
	stderr := newBoundedCapture(hostErrorOutputLimit, func() {
		child.markOutputExceeded()
		go child.stopAfterSessionCancel(runner.grace)
	})
	stderrDone := make(chan struct{})
	go drain(child.stderr, stderr, stderrDone)
	stdout := &boundedReader{
		reader: child.stdout, remaining: hostInteractionOutputLimit,
		onOverflow: func() {
			child.markOutputExceeded()
			go child.stopAfterSessionCancel(runner.grace)
		},
	}
	stream := &hostStream{reader: stdout, writer: child.input}
	interactionContext, cancelInteraction := context.WithCancel(ctx)
	defer cancelInteraction()
	interactionDone := make(chan error, 1)
	go func() {
		interactionDone <- interact(interactionContext, stream, child.registerSession)
	}()

	var interactionErr error
	timedOut, canceled := false, false
	select {
	case interactionErr = <-interactionDone:
		timedOut, canceled = contextOutcome(ctx)
		if interactionErr != nil || timedOut || canceled {
			child.stopAfterSessionCancel(runner.grace)
		} else {
			child.stopAfterClose(runner.grace)
		}
	case <-child.waitDone:
		_ = child.input.Close()
		interactionErr = <-interactionDone
		child.stopAfterClose(runner.grace)
	case <-ctx.Done():
		timedOut, canceled = contextOutcome(ctx)
		child.stopAfterSessionCancel(runner.grace)
		cancelInteraction()
		interactionErr = <-interactionDone
	}
	child.stopAfterClose(runner.grace)
	<-child.waitDone
	<-stderrDone
	if !timedOut && !canceled {
		timedOut, canceled = contextOutcome(ctx)
	}
	result := child.result(timedOut, canceled, "", stderr.String())
	if result.OutputExceeded {
		return result, supervisor.ErrOutputLimit
	}
	if interactionErr != nil && !timedOut && !canceled {
		return result, interactionErr
	}
	if waitErr := child.waitError(); waitErr != nil && !timedOut && !canceled {
		var exitError *exec.ExitError
		if !errors.As(waitErr, &exitError) {
			return result, waitErr
		}
	}
	return result, nil
}

type exactChild struct {
	mu       sync.Mutex
	cmd      *exec.Cmd
	process  *os.Process
	stdin    io.WriteCloser
	stdout   io.ReadCloser
	stderr   io.ReadCloser
	input    *serializedInput
	waitDone chan struct{}
	waitErr  error
	exited   bool

	stopOnce sync.Once

	sessionMu       sync.Mutex
	sessionID       string
	cancelRequested bool
	outputExceeded  bool
}

func startExactChild(request supervisor.Request, kind hostRequestKind) (*exactChild, error) {
	valid := false
	switch kind {
	case hostCursorDiscovery:
		valid = validHostRequest(request, false) && validDiscoveryArguments(request.Arguments)
	case hostCursorInteractive:
		valid = validHostRequest(request, true) && validInteractiveArguments(request.Arguments)
	case hostCodex:
		valid = validCodexHostRequest(request)
	}
	if !valid {
		return nil, errInvalidHostRequest
	}
	command := exec.Command(request.Executable, request.Arguments...)
	command.Dir = request.WorkingDir
	command.Env = hostEnvironment(request)
	stdin, err := command.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return nil, err
	}
	stderr, err := command.StderrPipe()
	if err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		return nil, err
	}
	child := &exactChild{
		cmd: command, stdin: stdin, stdout: stdout, stderr: stderr,
		input: &serializedInput{writer: stdin}, waitDone: make(chan struct{}),
	}
	if err := command.Start(); err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		_ = stderr.Close()
		return nil, err
	}
	child.process = command.Process
	go child.wait()
	return child, nil
}

func (child *exactChild) wait() {
	err := child.cmd.Wait()
	child.mu.Lock()
	child.waitErr = err
	child.exited = true
	close(child.waitDone)
	child.mu.Unlock()
}

func (child *exactChild) registerSession(sessionID string) {
	if sessionID == "" || !validHostText(sessionID, 200, false) {
		return
	}
	child.sessionMu.Lock()
	defer child.sessionMu.Unlock()
	if child.cancelRequested || !child.live() {
		return
	}
	child.sessionID = sessionID
}

func (child *exactChild) stopAfterSessionCancel(grace time.Duration) {
	child.stopOnce.Do(func() {
		child.sessionMu.Lock()
		child.cancelRequested = true
		sessionID := child.sessionID
		child.sessionMu.Unlock()
		if sessionID != "" && child.live() {
			_ = child.input.WriteBounded(sessionCancelMessage(sessionID), hostCancelWriteTimeout)
		}
		_ = child.input.Close()
		child.terminateAfterGrace(grace)
	})
}

func (child *exactChild) stopAfterClose(grace time.Duration) {
	child.stopOnce.Do(func() {
		_ = child.input.Close()
		child.terminateAfterGrace(grace)
	})
}

func (child *exactChild) terminateAfterGrace(grace time.Duration) {
	if child.waitFor(grace) {
		return
	}
	if child.signal(syscall.SIGTERM) && child.waitFor(grace) {
		return
	}
	if child.kill() {
		_ = child.waitFor(grace)
	}
}

func (child *exactChild) waitFor(duration time.Duration) bool {
	if duration <= 0 {
		select {
		case <-child.waitDone:
			return true
		default:
			return false
		}
	}
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-child.waitDone:
		return true
	case <-timer.C:
		return false
	}
}

func (child *exactChild) signal(signal os.Signal) bool {
	child.mu.Lock()
	defer child.mu.Unlock()
	if child.exited || child.process == nil || (child.cmd.ProcessState != nil && child.cmd.ProcessState.Exited()) {
		return false
	}
	return child.process.Signal(signal) == nil
}

func (child *exactChild) kill() bool {
	child.mu.Lock()
	defer child.mu.Unlock()
	if child.exited || child.process == nil || (child.cmd.ProcessState != nil && child.cmd.ProcessState.Exited()) {
		return false
	}
	return child.process.Kill() == nil
}

func (child *exactChild) live() bool {
	child.mu.Lock()
	defer child.mu.Unlock()
	return !child.exited && child.process != nil && (child.cmd.ProcessState == nil || !child.cmd.ProcessState.Exited())
}

func (child *exactChild) markOutputExceeded() {
	child.mu.Lock()
	child.outputExceeded = true
	child.mu.Unlock()
}

func (child *exactChild) result(timedOut, canceled bool, stdout, stderr string) supervisor.Result {
	child.mu.Lock()
	defer child.mu.Unlock()
	exitCode := -1
	if child.cmd.ProcessState != nil {
		exitCode = child.cmd.ProcessState.ExitCode()
	}
	return supervisor.Result{
		ExitCode: exitCode, StandardOutput: stdout, StandardError: stderr,
		TimedOut: timedOut, Canceled: canceled, OutputExceeded: child.outputExceeded,
	}
}

func (child *exactChild) waitError() error {
	child.mu.Lock()
	defer child.mu.Unlock()
	return child.waitErr
}

type serializedInput struct {
	mu     sync.Mutex
	writer io.WriteCloser
	closed bool
}

func (input *serializedInput) Write(data []byte) (int, error) {
	input.mu.Lock()
	defer input.mu.Unlock()
	if input.closed {
		return 0, io.ErrClosedPipe
	}
	return input.writeWithDeadline(data, hostInteractionWriteTimeout)
}

func (input *serializedInput) WriteBounded(data []byte, timeout time.Duration) error {
	input.mu.Lock()
	defer input.mu.Unlock()
	if input.closed {
		return io.ErrClosedPipe
	}
	_, err := input.writeWithDeadline(data, timeout)
	return err
}

func (input *serializedInput) writeWithDeadline(data []byte, timeout time.Duration) (int, error) {
	if deadlineWriter, ok := input.writer.(interface{ SetWriteDeadline(time.Time) error }); ok {
		if err := deadlineWriter.SetWriteDeadline(time.Now().Add(timeout)); err != nil {
			return 0, err
		}
		defer deadlineWriter.SetWriteDeadline(time.Time{})
	}
	return input.writer.Write(data)
}

func (input *serializedInput) Close() error {
	input.mu.Lock()
	defer input.mu.Unlock()
	if input.closed {
		return nil
	}
	input.closed = true
	return input.writer.Close()
}

type hostStream struct {
	reader io.Reader
	writer io.Writer
}

func (stream *hostStream) Read(data []byte) (int, error)  { return stream.reader.Read(data) }
func (stream *hostStream) Write(data []byte) (int, error) { return stream.writer.Write(data) }

type boundedCapture struct {
	mu         sync.Mutex
	data       bytes.Buffer
	remaining  int
	overflowed bool
	overflow   chan struct{}
	onOverflow func()
	once       sync.Once
}

func newBoundedCapture(limit int, onOverflow func()) *boundedCapture {
	return &boundedCapture{remaining: limit, overflow: make(chan struct{}), onOverflow: onOverflow}
}

func (capture *boundedCapture) Write(data []byte) (int, error) {
	capture.mu.Lock()
	if capture.overflowed {
		capture.mu.Unlock()
		return 0, supervisor.ErrOutputLimit
	}
	kept := data
	if len(kept) > capture.remaining {
		kept = kept[:capture.remaining]
	}
	_, _ = capture.data.Write(kept)
	capture.remaining -= len(kept)
	overflow := len(kept) != len(data)
	if overflow {
		capture.overflowed = true
	}
	capture.mu.Unlock()
	if overflow {
		capture.once.Do(func() {
			close(capture.overflow)
			if capture.onOverflow != nil {
				capture.onOverflow()
			}
		})
		return len(kept), supervisor.ErrOutputLimit
	}
	return len(kept), nil
}

func (capture *boundedCapture) String() string {
	capture.mu.Lock()
	defer capture.mu.Unlock()
	return capture.data.String()
}

func (capture *boundedCapture) overflowedChan() <-chan struct{} { return capture.overflow }

type boundedReader struct {
	mu         sync.Mutex
	reader     io.Reader
	remaining  int
	overflowed bool
	onOverflow func()
	once       sync.Once
}

func (reader *boundedReader) Read(data []byte) (int, error) {
	reader.mu.Lock()
	if reader.overflowed {
		reader.mu.Unlock()
		reader.notifyOverflow()
		return 0, supervisor.ErrOutputLimit
	}
	if reader.remaining == 0 {
		reader.mu.Unlock()
		var probe [1]byte
		read, err := reader.reader.Read(probe[:])
		if read > 0 {
			reader.mu.Lock()
			reader.overflowed = true
			reader.mu.Unlock()
			reader.notifyOverflow()
			return 0, supervisor.ErrOutputLimit
		}
		return 0, err
	}
	limit := len(data)
	if limit > reader.remaining {
		limit = reader.remaining
	}
	reader.mu.Unlock()

	read, err := reader.reader.Read(data[:limit])
	reader.mu.Lock()
	reader.remaining -= read
	overflow := read == limit && limit < len(data) && err == nil
	if overflow {
		reader.overflowed = true
	}
	reader.mu.Unlock()
	if overflow {
		reader.notifyOverflow()
		return read, supervisor.ErrOutputLimit
	}
	return read, err
}

func (reader *boundedReader) notifyOverflow() {
	reader.once.Do(func() {
		if reader.onOverflow != nil {
			reader.onOverflow()
		}
	})
}

func drain(reader io.Reader, capture io.Writer, done chan<- struct{}) {
	_, _ = io.Copy(capture, reader)
	close(done)
}

func contextOutcome(ctx context.Context) (bool, bool) {
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return true, false
	}
	if errors.Is(ctx.Err(), context.Canceled) {
		return false, true
	}
	return false, false
}

func sessionCancelMessage(sessionID string) []byte {
	message, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0", "method": "session/cancel", "params": map[string]string{"sessionId": sessionID},
	})
	return append(message, '\n')
}

func validHostRequest(request supervisor.Request, interactive bool) bool {
	if !validExecutable(request.Executable) || !validDirectory(request.WorkingDir) || !validDirectory(request.HomeDir) ||
		len(request.Input) != 0 || len(request.Credentials) != 0 || containsInvalidText(request.EgressProfileKey) {
		return false
	}
	if interactive {
		return validInteractiveArguments(request.Arguments)
	}
	return validDiscoveryArguments(request.Arguments)
}

func validCodexHostRequest(request supervisor.Request) bool {
	if !validExecutableNamed(request.Executable, "codex") || !validDirectory(request.WorkingDir) || !validDirectory(request.HomeDir) ||
		containsInvalidText(request.EgressProfileKey) {
		return false
	}
	if len(request.Input) == 0 {
		return len(request.Credentials) == 0 && validCodexDiscoveryArguments(request.Arguments)
	}
	return request.EgressProfileKey != "" && validHostText(string(request.Input), hostCodexInputLimit, true) &&
		validCodexCredentials(request.Credentials, request.HomeDir) &&
		validCodexExecutionArguments(request.Arguments, request.WorkingDir)
}

func validExecutable(path string) bool {
	return validExecutableNamed(path, "cursor-agent", "agent")
}

func validExecutableNamed(path string, names ...string) bool {
	if !filepath.IsAbs(path) || strings.ContainsAny(path, "\r\n\x00") {
		return false
	}
	base := filepath.Base(path)
	allowed := false
	for _, name := range names {
		if base == name {
			allowed = true
			break
		}
	}
	if !allowed {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0
}

func validDirectory(path string) bool {
	if !filepath.IsAbs(path) || strings.ContainsAny(path, "\r\n\x00") {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func validDiscoveryArguments(arguments []string) bool {
	return len(arguments) == 1 && arguments[0] == "--list-models"
}

func validCodexDiscoveryArguments(arguments []string) bool {
	return len(arguments) == 2 && arguments[0] == "debug" && arguments[1] == "models"
}

func validCodexExecutionArguments(arguments []string, workingDir string) bool {
	if len(arguments) < len(codexExecutionPrefix)+3 {
		return false
	}
	for index, expected := range codexExecutionPrefix {
		if arguments[index] != expected {
			return false
		}
	}
	index := len(codexExecutionPrefix)
	if len(arguments) < index+4 || arguments[index] != "--disable" || arguments[index+1] != "shell_tool" ||
		arguments[index+2] != "--disable" || arguments[index+3] != "unified_exec" {
		return false
	}
	index += 4
	if len(arguments) < index+3 || arguments[index] != "-C" || arguments[index+1] != workingDir {
		return false
	}
	index += 2
	if index < len(arguments) && arguments[index] == "-m" {
		if len(arguments) < index+2 || !validHostText(arguments[index+1], 200, false) {
			return false
		}
		index += 2
	}
	return len(arguments) == index+1 && arguments[index] == "-"
}

func validCodexCredentials(credentials map[string]string, homeDir string) bool {
	return len(credentials) == 1 && credentials["CODEX_HOME"] == homeDir
}

func validInteractiveArguments(arguments []string) bool {
	if len(arguments) == 1 {
		return arguments[0] == "acp"
	}
	return len(arguments) == 3 && arguments[0] == "--model" && validHostText(arguments[1], 200, false) && arguments[2] == "acp"
}

func validHostText(value string, maximum int, allowWhitespaceControls bool) bool {
	if value == "" || len(value) > maximum || !utf8.ValidString(value) {
		return false
	}
	for _, character := range value {
		if unicode.IsControl(character) && (!allowWhitespaceControls || (character != '\n' && character != '\r' && character != '\t')) {
			return false
		}
	}
	return true
}

func containsInvalidText(value string) bool {
	for _, character := range value {
		if unicode.IsControl(character) {
			return true
		}
	}
	return !utf8.ValidString(value)
}

func hostEnvironment(request supervisor.Request) []string {
	environment := []string{"HOME=" + request.HomeDir, "LANG=C.UTF-8", "PATH=" + os.Getenv("PATH")}
	if filepath.Base(request.Executable) == "codex" {
		environment = append(environment, "CODEX_HOME="+request.HomeDir)
	}
	return environment
}
