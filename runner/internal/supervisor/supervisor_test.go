//go:build linux && amd64

package supervisor

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

var testBinaries string

func TestMain(m *testing.M) {
	directory, err := os.MkdirTemp("", "navishai-supervisor-")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(directory)
	testBinaries = directory
	build := func(output string, arguments ...string) {
		command := exec.Command("go", append([]string{"build", "-o", filepath.Join(directory, output)}, arguments...)...)
		if result, buildErr := command.CombinedOutput(); buildErr != nil {
			panic(string(result) + buildErr.Error())
		}
	}
	build("navishai-exec", "../../cmd/navishai-exec")
	source := filepath.Join(directory, "target.go")
	if err := os.WriteFile(source, []byte(testTarget), 0o600); err != nil {
		panic(err)
	}
	build("target", source)
	os.Exit(m.Run())
}

func TestRunUsesOnlyScopedEnvironment(t *testing.T) {
	working := t.TempDir()
	supervisor := testSupervisor(t, working)
	t.Setenv("HOST_SECRET", "must-not-leak")
	result, err := supervisor.Run(context.Background(), Request{
		Executable: targetPath(), Arguments: []string{"environment"}, WorkingDir: working,
		Credentials: map[string]string{"SCOPED_TOKEN": "present"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.StandardOutput != "present|" {
		t.Fatalf("unexpected environment %q", result.StandardOutput)
	}
}

func TestRunDeniesFilesystemOutsideRoots(t *testing.T) {
	working := t.TempDir()
	outside := t.TempDir()
	path := filepath.Join(outside, "secret")
	if err := os.WriteFile(path, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	result, err := testSupervisor(t, working).Run(context.Background(), Request{
		Executable: targetPath(), Arguments: []string{"read", path}, WorkingDir: working,
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.ExitCode != 0 || !strings.Contains(result.StandardOutput, "permission denied") {
		t.Fatalf("outside read was not denied: %#v", result)
	}
}

func TestRunAllowsWritesInsideWorkingRoot(t *testing.T) {
	working := t.TempDir()
	path := filepath.Join(working, "result")
	result, err := testSupervisor(t, working).Run(context.Background(), Request{
		Executable: targetPath(), Arguments: []string{"write", path}, WorkingDir: working,
	})
	if err != nil || result.ExitCode != 0 {
		t.Fatalf("write result=%#v err=%v", result, err)
	}
	if content, readErr := os.ReadFile(path); readErr != nil || string(content) != "result" {
		t.Fatalf("written content %q, err=%v", content, readErr)
	}
}

func TestRunDeniesNetwork(t *testing.T) {
	working := t.TempDir()
	result, err := testSupervisor(t, working).Run(context.Background(), Request{
		Executable: targetPath(), Arguments: []string{"socket"}, WorkingDir: working,
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.ExitCode != 0 || strings.TrimSpace(result.StandardOutput) != "operation not permitted" {
		t.Fatalf("socket was not denied: %#v", result)
	}
}

func TestRunTimesOutAndReapsProcess(t *testing.T) {
	working := t.TempDir()
	supervisor := testSupervisor(t, working)
	supervisor.limits.WallTime = 50 * time.Millisecond
	started := time.Now()
	result, err := supervisor.Run(context.Background(), Request{
		Executable: targetPath(), Arguments: []string{"sleep"}, WorkingDir: working,
	})
	if err != nil || !result.TimedOut || result.Canceled || time.Since(started) > time.Second {
		t.Fatalf("timeout did not terminate promptly: result=%#v err=%v", result, err)
	}
}

func TestRunHonorsCancellation(t *testing.T) {
	working := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	result, err := testSupervisor(t, working).Run(ctx, Request{
		Executable: targetPath(), Arguments: []string{"sleep"}, WorkingDir: working,
	})
	if err != nil || !result.Canceled || result.TimedOut {
		t.Fatalf("cancellation result=%#v err=%v", result, err)
	}
}

func TestRunKillsDescendantsWhenParentExits(t *testing.T) {
	working := t.TempDir()
	pidPath := filepath.Join(working, "child.pid")
	result, err := testSupervisor(t, working).Run(context.Background(), Request{
		Executable: targetPath(), Arguments: []string{"spawn", pidPath}, WorkingDir: working,
	})
	if err != nil || result.ExitCode != 0 || result.TimedOut {
		t.Fatalf("spawn result=%#v err=%v", result, err)
	}
	content, err := os.ReadFile(pidPath)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(string(content))
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for processAlive(pid) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if processAlive(pid) {
		t.Fatalf("descendant %d survived", pid)
	}
}

func processAlive(pid int) bool {
	if err := syscall.Kill(pid, 0); errors.Is(err, syscall.ESRCH) {
		return false
	}
	status, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "stat"))
	return err == nil && !strings.Contains(string(status), ") Z ")
}

func TestRunKillsOnOutputOverflow(t *testing.T) {
	working := t.TempDir()
	supervisor := testSupervisor(t, working)
	supervisor.limits.OutputBytes = 64
	result, err := supervisor.Run(context.Background(), Request{
		Executable: targetPath(), Arguments: []string{"output"}, WorkingDir: working,
	})
	if !errors.Is(err, ErrOutputLimit) || !result.OutputExceeded || len(result.StandardOutput) > 64 {
		t.Fatalf("output limit result=%#v err=%v", result, err)
	}
}

func TestRunReturnsNonzeroExit(t *testing.T) {
	working := t.TempDir()
	result, err := testSupervisor(t, working).Run(context.Background(), Request{
		Executable: targetPath(), Arguments: []string{"exit"}, WorkingDir: working,
	})
	if err != nil || result.ExitCode != 7 {
		t.Fatalf("nonzero result=%#v err=%v", result, err)
	}
}

func TestRunRejectsEscapesAndOversizedInput(t *testing.T) {
	working := t.TempDir()
	supervisor := testSupervisor(t, working)
	escape := filepath.Join(working, "escape")
	if err := os.Symlink(t.TempDir(), escape); err != nil {
		t.Fatal(err)
	}
	requests := []Request{
		{Executable: "/bin/true", WorkingDir: working},
		{Executable: filepath.Join(testBinaries, "navishai-exec"), WorkingDir: working},
		{Executable: targetPath(), WorkingDir: escape},
		{Executable: targetPath(), WorkingDir: working, Input: make([]byte, maxInputBytes+1)},
		{Executable: targetPath(), WorkingDir: working, Arguments: []string{strings.Repeat("x", maxArgumentBytes+1)}},
		{Executable: targetPath(), WorkingDir: working, Credentials: map[string]string{"bad": "value"}},
	}
	for index, request := range requests {
		if _, err := supervisor.Run(context.Background(), request); !errors.Is(err, ErrInvalidRequest) {
			t.Errorf("request %d: got %v", index, err)
		}
	}
}

func testSupervisor(t *testing.T, working string) *Supervisor {
	t.Helper()
	value, err := New(Config{
		HelperPath: filepath.Join(testBinaries, "navishai-exec"), AllowedExecutableRoots: []string{testBinaries},
		ApprovedExecutables: []string{targetPath()},
		AllowedWorkingRoots: []string{working}, RuntimeReadRoots: []string{testBinaries},
		Limits: Limits{WallTime: 2 * time.Second, CPUSeconds: 1, MemoryBytes: 2 * 1024 * 1024 * 1024,
			OpenFiles: 32, Processes: 4096, OutputBytes: 16 * 1024, KillGrace: 10 * time.Millisecond},
	})
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func targetPath() string { return filepath.Join(testBinaries, "target") }

const testTarget = `package main
import (
  "fmt"
  "os"
  "os/exec"
  "strconv"
  "strings"
  "syscall"
  "time"
)
func main() {
  switch os.Args[1] {
  case "environment": fmt.Print(os.Getenv("SCOPED_TOKEN") + "|" + os.Getenv("HOST_SECRET"))
  case "read": _, err := os.ReadFile(os.Args[2]); fmt.Print(err)
  case "write": if err := os.WriteFile(os.Args[2], []byte("result"), 0600); err != nil { fmt.Print(err); os.Exit(1) }
  case "socket": _, _, errno := syscall.Syscall(syscall.SYS_SOCKET, syscall.AF_INET, syscall.SOCK_STREAM, 0); fmt.Print(errno)
  case "sleep": time.Sleep(10 * time.Second)
  case "spawn":
	output, err := os.OpenFile(os.Args[2]+".log", os.O_CREATE|os.O_WRONLY, 0600); if err != nil { fmt.Print(err); os.Exit(1) }
    command := exec.Command(os.Args[0], "sleep"); command.Stdin = output; command.Stdout = output; command.Stderr = output
	if err := command.Start(); err != nil { fmt.Print(err); os.Exit(1) }
	if err := os.WriteFile(os.Args[2], []byte(strconv.Itoa(command.Process.Pid)), 0600); err != nil { fmt.Print(err); os.Exit(1) }
  case "output": for { fmt.Print(strings.Repeat("x", 1024)) }
  case "exit": os.Exit(7)
  }
}
`
