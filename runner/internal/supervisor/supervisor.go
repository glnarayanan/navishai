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
	"sort"
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
	maxEgressProfiles = 32
)

var (
	ErrInvalidRequest = errors.New("invalid supervised process request")
	ErrOutputLimit    = errors.New("process output limit exceeded")
	credentialPattern = regexp.MustCompile(`^[A-Z][A-Z0-9_]{0,63}$`)
	profileKeyPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)
)

var allowedEgressEnvironment = map[string]bool{
	"ALL_PROXY": true, "HTTP_PROXY": true, "HTTPS_PROXY": true, "NO_PROXY": true,
	"SSL_CERT_DIR": true, "SSL_CERT_FILE": true,
}

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

type Supervisor struct {
	helperPath          string
	executableRoots     []string
	approvedExecutables map[string]bool
	workingRoots        []string
	homeRoots           []string
	runtimeReadRoots    []string
	namespaceLauncher   string
	egressProfiles      map[string]resolvedEgressProfile
	limits              Limits
}

type resolvedEgressProfile struct {
	executable       string
	userNamespace    *os.File
	networkNamespace *os.File
	environment      []string
}

type preparedRequest struct {
	commandPath string
	arguments   []string
	workingDir  string
	environment []string
	extraFiles  []*os.File
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
	homeRoots := []string(nil)
	if len(config.AllowedHomeRoots) > 0 {
		homeRoots, err = realRoots(config.AllowedHomeRoots)
		if err != nil {
			return nil, err
		}
	}
	runtimeReadRoots, err := realRoots(config.RuntimeReadRoots)
	if err != nil {
		return nil, err
	}
	approvedExecutables := make(map[string]bool, len(config.ApprovedExecutables))
	for _, path := range config.ApprovedExecutables {
		executable, approvalErr := approvedFile(path, executableRoots)
		if approvalErr != nil {
			return nil, approvalErr
		}
		if executable == helper {
			return nil, ErrInvalidRequest
		}
		approvedExecutables[executable] = true
	}
	launcher := ""
	if len(config.EgressProfiles) > 0 {
		launcher, err = approvedExecutable(config.NamespaceLauncherPath)
		if err != nil || launcher == helper || approvedExecutables[launcher] {
			return nil, ErrInvalidRequest
		}
	}
	egressProfiles, err := resolveEgressProfiles(config.EgressProfiles, executableRoots, approvedExecutables)
	if err != nil {
		return nil, err
	}
	return &Supervisor{helperPath: helper, executableRoots: executableRoots, approvedExecutables: approvedExecutables,
		workingRoots: workingRoots, homeRoots: homeRoots, runtimeReadRoots: runtimeReadRoots, namespaceLauncher: launcher,
		egressProfiles: egressProfiles, limits: config.Limits}, nil
}

func resolveEgressProfiles(values []EgressProfile, executableRoots []string, approved map[string]bool) (map[string]resolvedEgressProfile, error) {
	if len(values) > maxEgressProfiles {
		return nil, ErrInvalidRequest
	}
	result := make(map[string]resolvedEgressProfile, len(values))
	closeResult := func() {
		for _, profile := range result {
			_ = profile.userNamespace.Close()
			_ = profile.networkNamespace.Close()
		}
	}
	for _, value := range values {
		executable, err := approvedFile(value.Executable, executableRoots)
		if err != nil || !approved[executable] || !profileKeyPattern.MatchString(value.Key) {
			closeResult()
			return nil, ErrInvalidRequest
		}
		if _, exists := result[value.Key]; exists {
			closeResult()
			return nil, ErrInvalidRequest
		}
		userNamespace, networkNamespace, err := openNamespacePair(value.UserNamespacePath, value.NetworkNamespacePath)
		if err != nil {
			closeResult()
			return nil, err
		}
		environment, err := egressEnvironment(value.Environment)
		if err != nil {
			_ = userNamespace.Close()
			_ = networkNamespace.Close()
			closeResult()
			return nil, err
		}
		result[value.Key] = resolvedEgressProfile{
			executable: executable, userNamespace: userNamespace, networkNamespace: networkNamespace, environment: environment,
		}
	}
	return result, nil
}

func openNamespace(path string, expectedType uintptr) (*os.File, error) {
	if !filepath.IsAbs(path) {
		return nil, ErrInvalidRequest
	}
	namespace, err := os.Open(path)
	if err != nil {
		return nil, ErrInvalidRequest
	}
	var filesystem syscall.Statfs_t
	const namespaceFilesystem = 0x6e736673
	if syscall.Fstatfs(int(namespace.Fd()), &filesystem) != nil || uint64(filesystem.Type) != namespaceFilesystem {
		_ = namespace.Close()
		return nil, ErrInvalidRequest
	}
	const namespaceGetType = 0xb703
	namespaceType, _, errno := syscall.RawSyscall(syscall.SYS_IOCTL, namespace.Fd(), namespaceGetType, 0)
	if errno != 0 || namespaceType != expectedType {
		_ = namespace.Close()
		return nil, ErrInvalidRequest
	}
	return namespace, nil
}

func openNamespacePair(userPath, networkPath string) (*os.File, *os.File, error) {
	const cloneNewUser = 0x10000000
	const cloneNewNetwork = 0x40000000
	userNamespace, err := openNamespace(userPath, cloneNewUser)
	if err != nil {
		return nil, nil, err
	}
	networkNamespace, err := openNamespace(networkPath, cloneNewNetwork)
	if err != nil {
		_ = userNamespace.Close()
		return nil, nil, err
	}
	const namespaceGetUser = 0xb701
	ownerFD, _, errno := syscall.RawSyscall(syscall.SYS_IOCTL, networkNamespace.Fd(), namespaceGetUser, 0)
	if errno != 0 {
		_ = userNamespace.Close()
		_ = networkNamespace.Close()
		return nil, nil, ErrInvalidRequest
	}
	owner := os.NewFile(ownerFD, "network-user-namespace")
	defer owner.Close()
	var configuredInfo, ownerInfo syscall.Stat_t
	if syscall.Fstat(int(userNamespace.Fd()), &configuredInfo) != nil || syscall.Fstat(int(owner.Fd()), &ownerInfo) != nil ||
		configuredInfo.Dev != ownerInfo.Dev || configuredInfo.Ino != ownerInfo.Ino {
		_ = userNamespace.Close()
		_ = networkNamespace.Close()
		return nil, nil, ErrInvalidRequest
	}
	return userNamespace, networkNamespace, nil
}

func egressEnvironment(values map[string]string) ([]string, error) {
	keys := make([]string, 0, len(values))
	for key, value := range values {
		if !allowedEgressEnvironment[key] || len(value) > 4096 || strings.ContainsRune(value, 0) {
			return nil, ErrInvalidRequest
		}
		keys = append(keys, key)
	}
	sort.Strings(keys)
	result := make([]string, 0, len(keys))
	for _, key := range keys {
		result = append(result, key+"="+values[key])
	}
	return result, nil
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
	prepared, err := supervisor.prepare(request)
	if err != nil {
		return Result{}, err
	}
	runContext, cancel := context.WithTimeout(ctx, supervisor.limits.WallTime)
	defer cancel()
	command := exec.Command(prepared.commandPath, prepared.arguments...)
	command.Dir = prepared.workingDir
	command.Env = prepared.environment
	command.ExtraFiles = prepared.extraFiles
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
	waitErr, timedOut, canceled := supervisor.wait(ctx, runContext, command)
	result := processResult(command, output, timedOut, canceled)
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

func (supervisor *Supervisor) Interact(ctx context.Context, request Request, interact func(context.Context, io.ReadWriter) error) (Result, error) {
	if interact == nil || len(request.Input) != 0 {
		return Result{}, ErrInvalidRequest
	}
	prepared, err := supervisor.prepare(request)
	if err != nil {
		return Result{}, err
	}
	runContext, cancel := context.WithTimeout(ctx, supervisor.limits.WallTime)
	defer cancel()
	command := exec.Command(prepared.commandPath, prepared.arguments...)
	command.Dir = prepared.workingDir
	command.Env = prepared.environment
	command.ExtraFiles = prepared.extraFiles
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGKILL}
	stdin, err := command.StdinPipe()
	if err != nil {
		return Result{}, err
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		return Result{}, err
	}
	output := newBoundedOutput(supervisor.limits.OutputBytes)
	command.Stderr = output.stderr()
	exchange := &boundedExchange{reader: stdout, writer: stdin, output: output, inputRemaining: maxInputBytes}
	output.onOverflow = func() {
		if command.Process != nil {
			_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		}
	}
	if err := command.Start(); err != nil {
		return Result{}, fmt.Errorf("start supervised process: %w", err)
	}
	interactionDone := make(chan error, 1)
	go func() { interactionDone <- interact(runContext, exchange) }()
	waited := make(chan error, 1)
	go func() { waited <- command.Wait() }()
	var interactionErr, waitErr error
	timedOut, canceled := false, false
	select {
	case interactionErr = <-interactionDone:
		_ = stdin.Close()
		if interactionErr != nil {
			_ = syscall.Kill(-command.Process.Pid, syscall.SIGTERM)
		}
		select {
		case waitErr = <-waited:
		case <-runContext.Done():
			timedOut = errors.Is(runContext.Err(), context.DeadlineExceeded) && ctx.Err() == nil
			canceled = !timedOut
			_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
			waitErr = <-waited
		}
	case waitErr = <-waited:
		_ = stdin.Close()
		interactionErr = <-interactionDone
	case <-runContext.Done():
		timedOut = errors.Is(runContext.Err(), context.DeadlineExceeded) && ctx.Err() == nil
		canceled = !timedOut
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		waitErr = <-waited
		_ = stdin.Close()
		interactionErr = <-interactionDone
	}
	_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	result := processResult(command, output, timedOut, canceled)
	if result.OutputExceeded {
		return result, ErrOutputLimit
	}
	if interactionErr != nil && !timedOut && !canceled {
		return result, interactionErr
	}
	if waitErr != nil && !timedOut && !canceled {
		var exitError *exec.ExitError
		if !errors.As(waitErr, &exitError) {
			return result, waitErr
		}
	}
	return result, nil
}

func (supervisor *Supervisor) prepare(request Request) (preparedRequest, error) {
	executable, err := approvedFile(request.Executable, supervisor.executableRoots)
	if err != nil || !supervisor.approvedExecutables[executable] {
		return preparedRequest{}, ErrInvalidRequest
	}
	workingDir, err := approvedDirectory(request.WorkingDir, supervisor.workingRoots)
	if err != nil || len(request.Arguments) > maxArguments || len(request.Input) > maxInputBytes || len(request.Credentials) > maxCredentialKeys {
		return preparedRequest{}, ErrInvalidRequest
	}
	homeDir := workingDir
	if request.HomeDir != "" {
		if request.HomeDir == request.WorkingDir {
			homeDir = workingDir
		} else {
			homeDir, err = approvedDirectory(request.HomeDir, supervisor.homeRoots)
			if err != nil {
				return preparedRequest{}, ErrInvalidRequest
			}
		}
	}
	argumentBytes := 0
	for _, argument := range request.Arguments {
		if strings.ContainsRune(argument, 0) {
			return preparedRequest{}, ErrInvalidRequest
		}
		argumentBytes += len(argument)
	}
	if argumentBytes > maxArgumentBytes {
		return preparedRequest{}, ErrInvalidRequest
	}
	environment := []string{
		"HOME=" + homeDir, "LANG=C.UTF-8",
		"NAVISHAI_LIMIT_CPU_SECONDS=" + strconv.FormatUint(supervisor.limits.CPUSeconds, 10),
		"NAVISHAI_LIMIT_MEMORY_BYTES=" + strconv.FormatUint(supervisor.limits.MemoryBytes, 10),
		"NAVISHAI_LIMIT_OPEN_FILES=" + strconv.FormatUint(supervisor.limits.OpenFiles, 10),
		"NAVISHAI_LIMIT_PROCESSES=" + strconv.FormatUint(supervisor.limits.Processes, 10),
	}
	commandPath := supervisor.helperPath
	commandArguments := append([]string{executable}, request.Arguments...)
	var extraFiles []*os.File
	if request.EgressProfileKey == "" {
		environment = append(environment, "NAVISHAI_DENY_NETWORK=1")
	} else {
		profile, ok := supervisor.egressProfiles[request.EgressProfileKey]
		if !ok || profile.executable != executable {
			return preparedRequest{}, ErrInvalidRequest
		}
		commandPath = supervisor.namespaceLauncher
		commandArguments = append([]string{supervisor.helperPath, executable}, request.Arguments...)
		environment = append(environment, "NAVISHAI_EXEC_ALLOW_NETWORK=1")
		environment = append(environment, profile.environment...)
		extraFiles = []*os.File{profile.userNamespace, profile.networkNamespace}
	}
	readRootValues := append([]string{}, supervisor.runtimeReadRoots...)
	readRootValues = append(readRootValues, supervisor.executableRoots...)
	if homeDir != workingDir {
		readRootValues = append(readRootValues, homeDir)
	}
	readRoots, err := json.Marshal(readRootValues)
	if err != nil {
		return preparedRequest{}, ErrInvalidRequest
	}
	writeRoots, err := json.Marshal([]string{workingDir})
	if err != nil {
		return preparedRequest{}, ErrInvalidRequest
	}
	environment = append(environment, "NAVISHAI_EXEC_READ_ROOTS="+string(readRoots), "NAVISHAI_EXEC_WRITE_ROOTS="+string(writeRoots))
	for key, value := range request.Credentials {
		if !credentialPattern.MatchString(key) || strings.HasPrefix(key, "NAVISHAI_") || allowedEgressEnvironment[key] ||
			key == "HOME" || key == "LANG" || len(value) > 16*1024 || strings.ContainsRune(value, 0) {
			return preparedRequest{}, ErrInvalidRequest
		}
		environment = append(environment, key+"="+value)
	}

	return preparedRequest{commandPath: commandPath, arguments: commandArguments, workingDir: workingDir, environment: environment, extraFiles: extraFiles}, nil
}

func (supervisor *Supervisor) wait(ctx, runContext context.Context, command *exec.Cmd) (error, bool, bool) {
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
	return waitErr, timedOut, canceled
}

func processResult(command *exec.Cmd, output *boundedOutput, timedOut, canceled bool) Result {
	return Result{
		ExitCode: command.ProcessState.ExitCode(), StandardOutput: output.stdoutString(),
		StandardError: output.stderrString(), TimedOut: timedOut, Canceled: canceled,
		OutputExceeded: output.exceeded(),
	}
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

type boundedExchange struct {
	reader         io.Reader
	writer         io.Writer
	output         *boundedOutput
	inputMu        sync.Mutex
	inputRemaining int
}

func (exchange *boundedExchange) Read(data []byte) (int, error) {
	count, err := exchange.reader.Read(data)
	if count > 0 {
		kept, limitErr := exchange.output.Write(data[:count])
		if limitErr != nil {
			return kept, limitErr
		}
	}
	return count, err
}

func (exchange *boundedExchange) Write(data []byte) (int, error) {
	exchange.inputMu.Lock()
	defer exchange.inputMu.Unlock()
	if len(data) > exchange.inputRemaining {
		return 0, ErrInvalidRequest
	}
	written, err := exchange.writer.Write(data)
	exchange.inputRemaining -= written
	return written, err
}
