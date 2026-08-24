package claude

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

// This smoke test is opt-in because it uses the customer's installed Claude
// subscription. It verifies the upstream CLI stream, not NavishAI isolation.
func TestLiveSubscriptionSmoke(t *testing.T) {
	if os.Getenv("NAVISHAI_CLAUDE_LIVE_SMOKE") != "1" {
		t.Skip("set NAVISHAI_CLAUDE_LIVE_SMOKE=1 to use the installed Claude subscription")
	}
	executable, err := exec.LookPath("claude")
	if err != nil {
		t.Fatal("claude is not installed")
	}
	configDir := os.Getenv("CLAUDE_CONFIG_DIR")
	if configDir == "" {
		t.Fatal("CLAUDE_CONFIG_DIR must name the existing customer-controlled login directory")
	}
	invocation := testInvocation()
	invocation.Executable = executable
	invocation.WorkingDir = t.TempDir()
	invocation.ClaudeConfigDir = configDir
	if model := os.Getenv("NAVISHAI_CLAUDE_SMOKE_MODEL"); model != "" {
		invocation.Model = model
	}
	invocation.Prompt = "Reply with exactly NAVISHAI_CLAUDE_SMOKE_OK and no other text."
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	result, err := New(time.Now).Execute(ctx, invocation, hostProcessRunner{}, func(event protocol.CanonicalEvent) error {
		return event.Validate()
	})
	if err != nil || result.Status != "completed" || result.Output != "NAVISHAI_CLAUDE_SMOKE_OK" {
		t.Fatalf("live Claude smoke failed: status=%s code=%s err=%v", result.Status, result.FailureCode, err)
	}
}

type hostProcessRunner struct{}

func (hostProcessRunner) Run(ctx context.Context, request supervisor.Request) (supervisor.Result, error) {
	command := exec.CommandContext(ctx, request.Executable, request.Arguments...)
	command.Dir = request.WorkingDir
	command.Env = []string{
		"HOME=" + request.WorkingDir, "LANG=C.UTF-8", "PATH=" + os.Getenv("PATH"),
		"CLAUDE_CONFIG_DIR=" + request.Credentials["CLAUDE_CONFIG_DIR"],
	}
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
