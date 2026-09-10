//go:build linux

package supervisor

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestWritablePersonalHomeDoesNotExposeAnotherAccount(t *testing.T) {
	requireIsolation(t)
	work, home, other := t.TempDir(), t.TempDir(), t.TempDir()
	process := testSupervisorWithHome(t, work, home)
	process.homeRoots = append(process.homeRoots, other)
	secret := filepath.Join(other, "auth.json")
	if err := os.WriteFile(secret, []byte("other account"), 0600); err != nil {
		t.Fatal(err)
	}
	run := func(mode, path string, writable bool) Result {
		t.Helper()
		result, err := process.Run(context.Background(), Request{Executable: targetPath(), Arguments: []string{mode, path}, WorkingDir: work, HomeDir: home, WritableHome: writable})
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	target := filepath.Join(home, "auth.json")
	if result := run("write", target, false); result.ExitCode == 0 {
		t.Fatal("ordinary home was writable")
	}
	if result := run("write", target, true); result.ExitCode != 0 {
		t.Fatalf("personal home not writable: %#v", result)
	}
	if result := run("read", secret, true); result.StandardOutput == "" {
		t.Fatal("another account readable")
	}
	if result := run("write", secret, true); result.ExitCode == 0 {
		t.Fatal("another account writable")
	}
}
