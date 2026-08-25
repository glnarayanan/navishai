package grok

import (
	"context"
	"io"
	"os"
	"os/exec"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

// This smoke test is opt-in because it uses the customer's installed Grok
// subscription. It verifies the upstream ACP stream, not NavishAI isolation.
func TestLiveSubscriptionSmoke(t *testing.T) {
	if os.Getenv("NAVISHAI_GROK_LIVE_SMOKE") != "1" {
		t.Skip("set NAVISHAI_GROK_LIVE_SMOKE=1 to use the installed Grok subscription")
	}
	executable, err := exec.LookPath("grok")
	if err != nil {
		t.Fatal("grok is not installed")
	}
	home := os.Getenv("GROK_HOME")
	if home == "" {
		t.Fatal("GROK_HOME must name the existing customer-controlled Grok directory")
	}
	invocation := testInvocation()
	invocation.Executable = executable
	invocation.WorkingDir = t.TempDir()
	invocation.GrokHome = home
	if model := os.Getenv("NAVISHAI_GROK_SMOKE_MODEL"); model != "" {
		invocation.Model = model
	}
	invocation.Prompt = "Reply with exactly NAVISHAI_GROK_SMOKE_OK and no other text."
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	result, err := New(time.Now).Execute(ctx, invocation, hostInteractiveRunner{}, func(event protocol.CanonicalEvent) error { return event.Validate() })
	if err != nil || result.Status != "completed" || result.Output != "NAVISHAI_GROK_SMOKE_OK" {
		t.Fatalf("live Grok smoke failed: status=%s code=%s err=%v", result.Status, result.FailureCode, err)
	}
}

type hostInteractiveRunner struct{}

func (hostInteractiveRunner) Interact(ctx context.Context, request supervisor.Request, interact func(context.Context, io.ReadWriter) error) (supervisor.Result, error) {
	command := exec.CommandContext(ctx, request.Executable, request.Arguments...)
	command.Dir = request.WorkingDir
	command.Env = []string{"HOME=" + request.WorkingDir, "LANG=C.UTF-8", "PATH=" + os.Getenv("PATH")}
	for key, value := range request.Credentials {
		command.Env = append(command.Env, key+"="+value)
	}
	stdin, err := command.StdinPipe()
	if err != nil {
		return supervisor.Result{}, err
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		return supervisor.Result{}, err
	}
	if err := command.Start(); err != nil {
		return supervisor.Result{}, err
	}
	exchangeErr := interact(ctx, struct {
		io.Reader
		io.Writer
	}{Reader: stdout, Writer: stdin})
	_ = stdin.Close()
	if exchangeErr != nil && command.Process != nil {
		_ = command.Process.Kill()
	}
	waitErr := command.Wait()
	result := supervisor.Result{}
	if command.ProcessState != nil {
		result.ExitCode = command.ProcessState.ExitCode()
	}
	if ctx.Err() != nil {
		result.TimedOut = true
	}
	if exchangeErr != nil {
		return result, exchangeErr
	}
	return result, waitErr
}
