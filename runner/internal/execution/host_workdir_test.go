package execution

import (
	"errors"
	"os"
	"testing"
)

func TestCreateHostWorkingDirectoryDistinguishesOccupancy(t *testing.T) {
	workRoot := t.TempDir()
	created, err := createHostWorkingDirectory(workRoot, "run-1")
	if err != nil {
		t.Fatalf("create empty run directory: %v", err)
	}
	if _, err := os.Stat(created); err != nil {
		t.Fatalf("created run directory: %v", err)
	}

	if _, err := createHostWorkingDirectory(workRoot, "run-1"); !errors.Is(err, ErrPolicyDenied) {
		t.Fatalf("occupied run directory: %v", err)
	}

	if err := os.RemoveAll(workRoot); err != nil {
		t.Fatal(err)
	}
	_, err = createHostWorkingDirectory(workRoot, "run-1")
	if errors.Is(err, ErrPolicyDenied) {
		t.Fatalf("missing work root was reported as policy denial: %v", err)
	}
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("missing work root: %v", err)
	}
}
