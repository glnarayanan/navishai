//go:build linux && amd64

package supervisor

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestRunEnforcesOptionalFileSizeLimit(t *testing.T) {
	requireIsolation(t)
	root := t.TempDir()
	process := testSupervisor(t, root)
	process.limits.FileBytes = 3
	output := filepath.Join(root, "bounded.txt")
	result, err := process.Run(context.Background(), Request{Executable: targetPath(), Arguments: []string{"write", output}, WorkingDir: root})
	if err != nil {
		t.Fatal(err)
	}
	if result.ExitCode == 0 {
		t.Fatal("oversized file write succeeded")
	}
	info, err := os.Stat(output)
	if err != nil {
		t.Fatal(err)
	}
	if info.Size() > 3 {
		t.Fatal("file size limit exceeded")
	}
}

func TestExplicitRuntimeReadFileDoesNotGrantItsDirectory(t *testing.T) {
	requireIsolation(t)
	work, private := t.TempDir(), t.TempDir()
	allowed, denied := filepath.Join(private, "allowed"), filepath.Join(private, "denied")
	for _, path := range []string{allowed, denied} {
		if err := os.WriteFile(path, []byte("text"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	process := testSupervisor(t, work)
	process.runtimeReadRoots = append(process.runtimeReadRoots, allowed)
	for _, scenario := range []struct {
		path     string
		readable bool
	}{{allowed, true}, {denied, false}} {
		result, err := process.Run(context.Background(), Request{Executable: targetPath(), Arguments: []string{"read", scenario.path}, WorkingDir: work})
		if err != nil {
			t.Fatal(err)
		}
		if (result.StandardOutput == "") != scenario.readable {
			t.Fatalf("unexpected file grant %s: %+v", scenario.path, result)
		}
	}
}
