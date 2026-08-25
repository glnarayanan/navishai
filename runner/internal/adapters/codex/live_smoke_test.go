package codex

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

// This smoke test is opt-in because it uses the customer's installed Codex
// subscription. It verifies the upstream CLI stream, not NavishAI isolation.
// Supervisor boundary tests remain mandatory in the normal suite.
func TestLiveSubscriptionSmoke(t *testing.T) {
	if os.Getenv("NAVISHAI_CODEX_LIVE_SMOKE") != "1" {
		t.Skip("set NAVISHAI_CODEX_LIVE_SMOKE=1 to use the installed Codex subscription")
	}
	executable, err := exec.LookPath("codex")
	if err != nil {
		t.Fatal("codex is not installed")
	}
	codexHome := os.Getenv("CODEX_HOME")
	if codexHome == "" {
		t.Fatal("CODEX_HOME must name the existing customer-controlled login directory")
	}
	invocation := testInvocation()
	invocation.Executable = executable
	invocation.WorkingDir = t.TempDir()
	invocation.CodexHome = codexHome
	invocation.Model = os.Getenv("NAVISHAI_CODEX_SMOKE_MODEL")
	invocation.Prompt = "Reply with exactly NAVISHAI_CODEX_SMOKE_OK and no other text."
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	result, err := New(time.Now).Execute(ctx, invocation, hostProcessRunner{}, func(event protocol.CanonicalEvent) error {
		return event.Validate()
	})
	if err != nil || result.Status != "completed" || result.Output != "NAVISHAI_CODEX_SMOKE_OK" {
		t.Fatalf("live Codex smoke failed: status=%s code=%s err=%v", result.Status, result.FailureCode, err)
	}
}

type hostProcessRunner struct{}

func (hostProcessRunner) Run(ctx context.Context, request supervisor.Request) (supervisor.Result, error) {
	command := exec.CommandContext(ctx, request.Executable, request.Arguments...)
	command.Dir = request.WorkingDir
	command.Env = []string{"HOME=" + request.WorkingDir, "LANG=C.UTF-8", "PATH=" + os.Getenv("PATH"), "CODEX_HOME=" + request.Credentials["CODEX_HOME"]}
	command.Stdin = bytes.NewReader(request.Input)
	var stdout, stderr bytes.Buffer
	command.Stdout, command.Stderr = &stdout, &stderr
	err := command.Run()
	result := supervisor.Result{StandardOutput: stdout.String(), StandardError: stderr.String()}
	if command.ProcessState != nil {
		result.ExitCode = command.ProcessState.ExitCode()
	}
	if ctx.Err() != nil {
		result.TimedOut = true
	}
	return result, err
}
