//go:build darwin

package cursorhost

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters"
	"github.com/glnarayanan/navishai/runner/internal/adapters/codex"
	"github.com/glnarayanan/navishai/runner/internal/adapters/cursor"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

type fakeRunner struct {
	runResult    supervisor.Result
	runCalls     int
	request      supervisor.Request
	codexResult  supervisor.Result
	codexCalls   int
	codexRequest supervisor.Request
}

func (runner *fakeRunner) Run(_ context.Context, request supervisor.Request) (supervisor.Result, error) {
	runner.runCalls++
	runner.request = request
	return runner.runResult, nil
}

func (runner *fakeRunner) RunCodex(_ context.Context, request supervisor.Request) (supervisor.Result, error) {
	runner.codexCalls++
	runner.codexRequest = request
	return runner.codexResult, nil
}

func (*fakeRunner) Interact(context.Context, supervisor.Request, func(context.Context, io.ReadWriter) error) (supervisor.Result, error) {
	return supervisor.Result{}, errors.New("unexpected interaction")
}

func (*fakeRunner) InteractSession(context.Context, supervisor.Request, func(context.Context, io.ReadWriter, adapters.SessionRegistrar) error) (supervisor.Result, error) {
	return supervisor.Result{}, errors.New("unexpected interaction")
}

func TestMain(main *testing.M) {
	if filepath.Base(os.Args[0]) == "cursor-agent" {
		os.Exit(runCursorFixture())
	}
	os.Exit(main.Run())
}

func runCursorFixture() int {
	directory, err := os.Getwd()
	if err != nil {
		return 1
	}
	if fileExists(filepath.Join(directory, "fixture-overflow")) {
		payload := bytes.Repeat([]byte("x"), 4096)
		for {
			_, _ = os.Stdout.Write(payload)
		}
	}
	if fileExists(filepath.Join(directory, "fixture-ignore-term")) {
		signal.Ignore(syscall.SIGTERM)
		select {}
	}
	if fileExists(filepath.Join(directory, "fixture-grandchild")) {
		pidPath := filepath.Join(directory, "grandchild.pid")
		lockPath := filepath.Join(directory, "grandchild.lock")
		if _, lockErr := os.OpenFile(lockPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600); lockErr == nil {
			command := exec.Command(os.Args[0])
			command.Dir = directory
			if startErr := command.Start(); startErr != nil {
				return 1
			}
			if writeErr := os.WriteFile(pidPath, []byte(strconv.Itoa(command.Process.Pid)), 0o600); writeErr != nil {
				_ = command.Process.Kill()
				return 1
			}
		}
		signal.Ignore(syscall.SIGTERM)
		select {}
	}
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := scanner.Text()
		switch {
		case strings.Contains(line, "initialize"):
			_, _ = io.WriteString(os.Stdout, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1}}\n")
		case strings.Contains(line, "session/new"):
			_, _ = io.WriteString(os.Stdout, "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"sessionId\":\"4d07f334-88ef-4fe4-a640-421e3ba79921\"}}\n")
		case strings.Contains(line, "session/cancel"):
			_ = os.WriteFile(filepath.Join(directory, "cancel.log"), []byte("cancel"), 0o600)
			return 0
		}
	}
	return 0
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func TestSourceRestrictsHostTrustedPathToCursorACP(t *testing.T) {
	runner := &fakeRunner{}
	source := NewWithRunner(runner, time.Now)
	invocation := cursor.Invocation{Admission: protocol.AdmissionRequest{Routing: protocol.RuntimeRouting{
		AdapterKey: cursor.AdapterKey, ExecutionMode: protocol.ExecutionModeHostTrusted,
		IsolationPolicy: protocol.IsolationPolicyHostTrustedAllowed,
	}}}
	if _, err := source.Execute(context.Background(), invocation, func(protocol.CanonicalEvent) error { return nil }); err == nil {
		t.Fatal("invalid Cursor invocation passed the source gate")
	}
	invocation.Admission.Routing.AdapterKey = "codex_subscription"
	if _, err := source.Execute(context.Background(), invocation, func(protocol.CanonicalEvent) error { return nil }); !errors.Is(err, ErrPolicyDenied) {
		t.Fatalf("non-Cursor host request was not denied: %v", err)
	}
	if runner.runCalls != 0 {
		t.Fatalf("source gate reached the process seam: %d", runner.runCalls)
	}
}

func TestSourceUsesCursorModelDiscoveryContract(t *testing.T) {
	workDir := t.TempDir()
	homeDir := t.TempDir()
	executable := filepath.Join(workDir, "cursor-agent")
	if err := os.WriteFile(executable, []byte("fixture"), 0o700); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{runResult: supervisor.Result{ExitCode: 0, StandardOutput: "gpt-5.5\ncomposer-2.5\n"}}
	source := NewWithRunner(runner, time.Now)
	models, err := source.DiscoverModels(context.Background(), executable, workDir, homeDir)
	if err != nil || len(models) != 2 || models[0].ID != "gpt-5.5" || runner.runCalls != 1 {
		t.Fatalf("unexpected source discovery: models=%#v calls=%d err=%v", models, runner.runCalls, err)
	}
	if len(runner.request.Arguments) != 1 || runner.request.Arguments[0] != "--list-models" || runner.request.HomeDir != homeDir {
		t.Fatalf("source did not use the exact Cursor discovery request: %#v", runner.request)
	}
}

func TestSourceUsesCodexModelDiscoveryContract(t *testing.T) {
	workDir := t.TempDir()
	homeDir := t.TempDir()
	executable := filepath.Join(workDir, "codex")
	if err := os.WriteFile(executable, []byte("fixture"), 0o700); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{codexResult: supervisor.Result{
		ExitCode:       0,
		StandardOutput: `{"models":[{"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","visibility":"list","default":true}]}`,
	}}
	source := NewWithRunner(runner, time.Now)
	models, err := source.DiscoverCodexModels(context.Background(), executable, workDir, homeDir)
	if err != nil || len(models) != 1 || models[0].ID != "gpt-5.6-sol" || runner.codexCalls != 1 {
		t.Fatalf("unexpected Codex source discovery: models=%#v calls=%d err=%v", models, runner.codexCalls, err)
	}
	if !reflect.DeepEqual(runner.codexRequest.Arguments, []string{"debug", "models"}) || runner.codexRequest.HomeDir != homeDir ||
		runner.codexRequest.Credentials != nil {
		t.Fatalf("source did not use the exact Codex discovery request: %#v", runner.codexRequest)
	}
}

func TestSourceDeniesCodexWhenHostPolicyIsNotExact(t *testing.T) {
	runner := &fakeRunner{codexResult: supervisor.Result{ExitCode: 0, StandardOutput: successfulCodexJSONL}}
	source := NewWithRunner(runner, time.Now)
	invocation := codex.Invocation{
		Admission: protocol.AdmissionRequest{Routing: protocol.RuntimeRouting{
			AdapterKey: codex.AdapterKey, ExecutionMode: protocol.ExecutionModeHostTrusted,
			IsolationPolicy: protocol.IsolationPolicyHostTrustedAllowed,
		}},
		CodexHome: "/runtime/codex", Prompt: "Return the sentinel.", EgressProfileKey: "model_api",
	}
	invocation.Admission.Routing.AdapterKey = cursor.AdapterKey
	if _, err := source.ExecuteCodex(context.Background(), invocation, func(protocol.CanonicalEvent) error { return nil }); !errors.Is(err, ErrPolicyDenied) {
		t.Fatalf("wrong Codex adapter was not denied: %v", err)
	}
	invocation.Admission.Routing.AdapterKey = codex.AdapterKey
	invocation.Admission.Routing.ExecutionMode = protocol.ExecutionModeStrongIsolated
	if _, err := source.ExecuteCodex(context.Background(), invocation, func(protocol.CanonicalEvent) error { return nil }); !errors.Is(err, ErrPolicyDenied) {
		t.Fatalf("non-host Codex request was not denied: %v", err)
	}
	if runner.codexCalls != 0 {
		t.Fatalf("Codex source gate reached the process seam: %d", runner.codexCalls)
	}
}

func TestCodexHostRequestRequiresExactArgumentsCredentialsAndBoundedInput(t *testing.T) {
	workDir := t.TempDir()
	homeDir := t.TempDir()
	executable := filepath.Join(workDir, "codex")
	if err := os.WriteFile(executable, []byte("fixture"), 0o700); err != nil {
		t.Fatal(err)
	}
	discovery := supervisor.Request{Executable: executable, Arguments: []string{"debug", "models"}, WorkingDir: workDir, HomeDir: homeDir}
	if !validCodexHostRequest(discovery) {
		t.Fatal("valid Codex discovery request was rejected")
	}
	for name, request := range map[string]supervisor.Request{
		"wrong executable": func() supervisor.Request {
			value := discovery
			value.Executable = filepath.Join(workDir, "cursor-agent")
			return value
		}(),
		"wrong discovery arguments": func() supervisor.Request {
			value := discovery
			value.Arguments = []string{"models"}
			return value
		}(),
		"discovery credentials": func() supervisor.Request {
			value := discovery
			value.Credentials = map[string]string{"CODEX_HOME": homeDir}
			return value
		}(),
	} {
		t.Run(name, func(t *testing.T) {
			if validCodexHostRequest(request) {
				t.Fatal("invalid Codex discovery request was accepted")
			}
		})
	}
	execution := supervisor.Request{
		Executable: executable,
		Arguments: []string{
			"exec", "--json", "--color", "never", "--sandbox", "read-only", "--ephemeral",
			"--ignore-user-config", "--ignore-rules", "-c", `approval_policy="never"`,
			"-c", `web_search="disabled"`, "--disable", "shell_tool", "--disable", "unified_exec",
			"-C", workDir, "-m", "gpt-5.6-sol", "-",
		},
		WorkingDir: workDir, HomeDir: homeDir, Input: []byte("Return the sentinel."),
		Credentials: map[string]string{"CODEX_HOME": homeDir}, EgressProfileKey: "model_api",
	}
	if !validCodexHostRequest(execution) {
		t.Fatal("valid Codex execution request was rejected")
	}
	environment := strings.Join(hostEnvironment(execution), "\x00")
	if !strings.Contains(environment, "HOME="+homeDir) || !strings.Contains(environment, "CODEX_HOME="+homeDir) ||
		strings.Contains(environment, "OPENAI_API_KEY") {
		t.Fatalf("Codex host environment was not reduced to the approved home: %q", environment)
	}
	invalidExecution := execution
	invalidExecution.Credentials = map[string]string{"CODEX_HOME": homeDir, "OPENAI_API_KEY": "sk-nope"}
	if validCodexHostRequest(invalidExecution) {
		t.Fatal("arbitrary Codex credentials were accepted")
	}
	invalidExecution = execution
	invalidExecution.Input = []byte("Return\x00the sentinel.")
	if validCodexHostRequest(invalidExecution) {
		t.Fatal("control data was accepted as Codex stdin")
	}
}

func TestDarwinRunnerExecutesCodexWithExactRequestAndEnvironment(t *testing.T) {
	workDir := t.TempDir()
	homeDir := t.TempDir()
	executable := filepath.Join(workDir, "codex")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > args.log\n" +
		"{ printf 'HOME=%s\\n' \"$HOME\"; printf 'LANG=%s\\n' \"$LANG\"; printf 'PATH=%s\\n' \"$PATH\"; printf 'CODEX_HOME=%s\\n' \"$CODEX_HOME\"; } > env.log\n" +
		"cat > input.log\nprintf '%s\\n' '{\"type\":\"done\"}'\n"
	if err := os.WriteFile(executable, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	arguments := []string{
		"exec", "--json", "--color", "never", "--sandbox", "read-only", "--ephemeral",
		"--ignore-user-config", "--ignore-rules", "-c", `approval_policy="never"`,
		"-c", `web_search="disabled"`, "--disable", "shell_tool", "--disable", "unified_exec",
		"-C", workDir, "-m", "gpt-5.6-sol", "-",
	}
	input := []byte("host prompt\n")
	request := supervisor.Request{
		Executable: executable, Arguments: arguments, WorkingDir: workDir, HomeDir: homeDir, Input: input,
		Credentials: map[string]string{"CODEX_HOME": homeDir}, EgressProfileKey: "model_api",
	}
	result, err := (&darwinRunner{grace: 10 * time.Millisecond}).RunCodex(context.Background(), request)
	if err != nil || result.ExitCode != 0 || result.OutputExceeded || strings.TrimSpace(result.StandardOutput) != `{"type":"done"}` {
		t.Fatalf("Codex exact-child fixture did not complete within bounds: result=%#v err=%v", result, err)
	}
	argsBody, err := os.ReadFile(filepath.Join(workDir, "args.log"))
	if err != nil {
		t.Fatal(err)
	}
	actualArguments := strings.Split(strings.TrimSuffix(string(argsBody), "\n"), "\n")
	if !reflect.DeepEqual(actualArguments, arguments) {
		t.Fatalf("Codex fixture received unexpected argv: %#v", actualArguments)
	}
	actualInput, err := os.ReadFile(filepath.Join(workDir, "input.log"))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(actualInput, input) {
		t.Fatalf("Codex fixture received unexpected stdin: %q", actualInput)
	}
	envBody, err := os.ReadFile(filepath.Join(workDir, "env.log"))
	if err != nil {
		t.Fatal(err)
	}
	expectedEnvironment := []string{"HOME=" + homeDir, "LANG=C.UTF-8", "PATH=" + os.Getenv("PATH"), "CODEX_HOME=" + homeDir}
	actualEnvironment := strings.Split(strings.TrimSuffix(string(envBody), "\n"), "\n")
	if !reflect.DeepEqual(actualEnvironment, expectedEnvironment) {
		t.Fatalf("Codex fixture received unexpected environment: %#v", actualEnvironment)
	}
	withoutDisable := append([]string(nil), arguments[:len(codexExecutionPrefix)]...)
	withoutDisable = append(withoutDisable, "-C", workDir, "-m", "gpt-5.6-sol", "-")
	for name, invalid := range map[string]supervisor.Request{
		"missing disable flags": func() supervisor.Request {
			value := request
			value.Arguments = withoutDisable
			return value
		}(),
		"oversized input": func() supervisor.Request {
			value := request
			value.Input = bytes.Repeat([]byte("x"), 128*1024+1)
			return value
		}(),
		"invalid UTF-8 input": func() supervisor.Request {
			value := request
			value.Input = []byte{0xff}
			return value
		}(),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := (&darwinRunner{grace: 10 * time.Millisecond}).RunCodex(context.Background(), invalid); err == nil {
				t.Fatal("invalid Codex request was accepted")
			}
		})
	}
}

func TestDarwinRunnerSendsSessionCancelBeforeStoppingExactChild(t *testing.T) {
	workDir := t.TempDir()
	homeDir := t.TempDir()
	executable := writeCursorExecutable(t, workDir)
	request := supervisor.Request{Executable: executable, Arguments: []string{"acp"}, WorkingDir: workDir, HomeDir: homeDir}
	runner := &darwinRunner{grace: 50 * time.Millisecond}
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(20 * time.Millisecond)
		cancel()
	}()
	result, err := runner.InteractSession(ctx, request, func(ctx context.Context, stream io.ReadWriter, register adapters.SessionRegistrar) error {
		reader := bufio.NewReader(stream)
		if _, err := stream.Write([]byte("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n")); err != nil {
			return err
		}
		if _, err := reader.ReadString('\n'); err != nil {
			return err
		}
		if _, err := stream.Write([]byte("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/new\"}\n")); err != nil {
			return err
		}
		if _, err := reader.ReadString('\n'); err != nil {
			return err
		}
		register("4d07f334-88ef-4fe4-a640-421e3ba79921")
		<-ctx.Done()
		return ctx.Err()
	})
	if err != nil || !result.Canceled {
		t.Fatalf("unexpected cancellation result: %#v err=%v", result, err)
	}
	contents, err := os.ReadFile(filepath.Join(workDir, "cancel.log"))
	if err != nil || strings.TrimSpace(string(contents)) != "cancel" {
		t.Fatalf("session cancellation was not observed before child stop: %q err=%v", contents, err)
	}
}

func TestDarwinRunnerKillsChildWhenGracefulTerminationIsIgnored(t *testing.T) {
	workDir := t.TempDir()
	homeDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(workDir, "fixture-ignore-term"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	executable := writeCursorExecutable(t, workDir)
	runner := &darwinRunner{grace: 10 * time.Millisecond}
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(20 * time.Millisecond)
		cancel()
	}()
	result, err := runner.InteractSession(ctx, supervisor.Request{
		Executable: executable, Arguments: []string{"acp"}, WorkingDir: workDir, HomeDir: homeDir,
	}, func(ctx context.Context, _ io.ReadWriter, _ adapters.SessionRegistrar) error {
		<-ctx.Done()
		return ctx.Err()
	})
	if err != nil || !result.Canceled {
		t.Fatalf("ignored graceful termination was not contained: %#v err=%v", result, err)
	}
}

func TestDarwinRunnerBoundsACPOutput(t *testing.T) {
	workDir := t.TempDir()
	homeDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(workDir, "fixture-overflow"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	executable := writeCursorExecutable(t, workDir)
	runner := &darwinRunner{grace: 10 * time.Millisecond}
	result, err := runner.InteractSession(context.Background(), supervisor.Request{
		Executable: executable, Arguments: []string{"acp"}, WorkingDir: workDir, HomeDir: homeDir,
	}, func(_ context.Context, stream io.ReadWriter, _ adapters.SessionRegistrar) error {
		_, copyErr := io.Copy(io.Discard, stream)
		return copyErr
	})
	if !errors.Is(err, supervisor.ErrOutputLimit) || !result.OutputExceeded {
		t.Fatalf("ACP output was not bounded: %#v err=%v", result, err)
	}
}

func TestDarwinRunnerDoesNotTargetDetachedGrandchild(t *testing.T) {
	workDir := t.TempDir()
	homeDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(workDir, "fixture-grandchild"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	executable := writeCursorExecutable(t, workDir)
	runner := &darwinRunner{grace: 10 * time.Millisecond}
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		deadline := time.Now().Add(time.Second)
		for time.Now().Before(deadline) {
			if fileExists(filepath.Join(workDir, "grandchild.pid")) {
				cancel()
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
		cancel()
	}()
	result, err := runner.InteractSession(ctx, supervisor.Request{
		Executable: executable, Arguments: []string{"acp"}, WorkingDir: workDir, HomeDir: homeDir,
	}, func(ctx context.Context, _ io.ReadWriter, _ adapters.SessionRegistrar) error {
		<-ctx.Done()
		return ctx.Err()
	})
	if err != nil || !result.Canceled {
		t.Fatalf("grandchild fixture did not cancel the direct child: %#v err=%v", result, err)
	}
	data, readErr := os.ReadFile(filepath.Join(workDir, "grandchild.pid"))
	if readErr != nil {
		t.Fatalf("grandchild pid was not recorded: %v", readErr)
	}
	pid, parseErr := strconv.Atoi(strings.TrimSpace(string(data)))
	if parseErr != nil || pid <= 0 {
		t.Fatalf("invalid grandchild pid %q: %v", data, parseErr)
	}
	defer syscall.Kill(pid, syscall.SIGKILL)
	if err := syscall.Kill(pid, 0); err != nil {
		t.Fatalf("runner targeted or failed to retain the detached grandchild: pid=%d err=%v", pid, err)
	}
}

func writeCursorExecutable(t *testing.T, directory string) string {
	t.Helper()
	path := filepath.Join(directory, "cursor-agent")
	target, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}
	return path
}

const successfulCodexJSONL = `{"type":"thread.started","thread_id":"4d07f334-88ef-4fe4-a640-421e3ba79921"}
{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}
{"type":"item.completed","item":{"type":"agent_message","text":"NAVISHAI_RUNTIME_TEST_OK"}}
`
