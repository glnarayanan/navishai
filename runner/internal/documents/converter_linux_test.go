//go:build linux && amd64

package documents

import (
	"context"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
	"os"
	"strings"
	"testing"
)

func TestInstalledLibreOffice(t *testing.T) {
	fixture := os.Getenv("NAVISHAI_TEST_DOC_FIXTURE")
	helper := os.Getenv("NAVISHAI_TEST_EXEC_HELPER")
	if fixture == "" || helper == "" {
		t.Skip("set document fixture and built execution helper for deployed converter test")
	}
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	converter, err := New(root, helper)
	if err != nil {
		t.Fatal(err)
	}
	process := converter.runner
	converter.runner = fixtureProcess{run: func(request supervisor.Request) (supervisor.Result, error) {
		request.Credentials["SAL_LOG"] = "+WARN"
		result, err := process.Run(context.Background(), request)
		if err != nil || result.ExitCode != 0 {
			t.Logf("fixture converter result=%+v error=%v", result, err)
		}
		return result, err
	}}
	content, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	text, err := converter.Extract(context.Background(), content)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(text), "NavishAI document conversion") {
		t.Fatalf("unexpected conversion %q", text)
	}
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) != 0 {
		t.Fatal("retained document content")
	}
}

func TestInstalledConverterRejectsSharedReadableHomes(t *testing.T) {
	helper := os.Getenv("NAVISHAI_TEST_EXEC_HELPER")
	if helper == "" {
		t.Skip("set built execution helper")
	}
	parent := t.TempDir()
	root := parent + "/documents"
	if _, err := New(root, helper, parent); err == nil {
		t.Fatal("converter enabled beneath another runtime home")
	}
	if converter, err := New(root, helper, parent+"/not-installed"); err != nil || converter == nil {
		t.Fatal("unrelated missing runtime disabled converter", err)
	}
}
