package cursor

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

func TestLiveSubscriptionSmoke(t *testing.T) {
	if os.Getenv("NAVISHAI_CURSOR_LIVE_SMOKE") != "1" {
		t.Skip("set NAVISHAI_CURSOR_LIVE_SMOKE=1 to use the installed Cursor subscription")
	}
	executable, err := exec.LookPath("cursor-agent")
	if err != nil {
		executable, err = exec.LookPath("agent")
	}
	if err != nil {
		t.Fatal("Cursor CLI is not installed")
	}
	home := os.Getenv("NAVISHAI_CURSOR_HOME")
	if home == "" {
		t.Fatal("NAVISHAI_CURSOR_HOME must name the customer home containing the browser login")
	}
	invocation := testInvocation()
	invocation.Executable, invocation.WorkingDir, invocation.CursorHome = executable, t.TempDir(), home
	invocation.Prompt = "Reply with exactly NAVISHAI_CURSOR_SMOKE_OK and no other text."
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	result, err := New(time.Now).Execute(ctx, invocation, hostInteractiveRunner{}, func(event protocol.CanonicalEvent) error { return event.Validate() })
	if err != nil || result.Status != "completed" || result.Output != "NAVISHAI_CURSOR_SMOKE_OK" {
		t.Fatalf("live Cursor smoke failed: status=%s code=%s err=%v", result.Status, result.FailureCode, err)
	}
}

type hostInteractiveRunner struct{}

func (hostInteractiveRunner) Interact(ctx context.Context, request supervisor.Request, interact func(context.Context, io.ReadWriter) error) (supervisor.Result, error) {
	command := exec.CommandContext(ctx, request.Executable, request.Arguments...)
	command.Dir = request.WorkingDir
	command.Env = []string{"HOME=" + request.HomeDir, "LANG=C.UTF-8", "PATH=" + os.Getenv("PATH")}
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
