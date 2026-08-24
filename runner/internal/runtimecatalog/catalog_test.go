package runtimecatalog

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestDetectReportsOnlyResolvedRegisteredExecutables(t *testing.T) {
	directory := t.TempDir()
	executable := filepath.Join(directory, "fixture-runtime")
	if err := os.WriteFile(executable, []byte("#!/bin/sh\nprintf 'fixture 2.4.1\\n'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory)
	checkedAt := time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)
	catalog, err := New([]Definition{{
		AdapterKey: "fixture", ProtocolVersion: "v1", ExecutableNames: []string{"missing", "fixture-runtime"},
		VersionArguments: []string{"--version"}, Capabilities: []string{"tool_calling", "structured_output"},
		MinimumVersion: "2.0.0", MaximumVersion: "2.9.99",
	}}, func() time.Time { return checkedAt })
	if err != nil {
		t.Fatal(err)
	}

	installations := catalog.Detect(context.Background())
	if len(installations) != 1 {
		t.Fatalf("expected one installation, got %d", len(installations))
	}
	installation := installations[0]
	if installation.ExecutablePath != executable || installation.ExecutableVersion != "fixture 2.4.1" ||
		installation.AdapterKey != "fixture" || installation.HealthStatus != "available" ||
		installation.CompatibilityStatus != "compatible" ||
		installation.AccountMetadata["authentication"] != "managed_on_runner" || len(installation.DetectionKey) != 64 {
		t.Fatalf("unexpected installation %#v", installation)
	}
}

func TestCompatibilityBlocksVersionsOutsideMaintainedRange(t *testing.T) {
	status, reason := compatibilityFor("fixture 3.0.0", "2.0.0", "2.9.99")
	if status != "incompatible" || reason == "" {
		t.Fatalf("expected an incompatible result, got %q %q", status, reason)
	}
	status, reason = compatibilityFor("development build", "2.0.0", "2.9.99")
	if status != "unknown" || reason == "" {
		t.Fatalf("expected an unknown result, got %q %q", status, reason)
	}
}

func TestDetectOmitsUnregisteredAndMissingExecutables(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	catalog, err := New([]Definition{{
		AdapterKey: "fixture", ProtocolVersion: "v1", ExecutableNames: []string{"not-installed"},
		VersionArguments: []string{"--version"},
	}}, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	if installations := catalog.Detect(context.Background()); len(installations) != 0 {
		t.Fatalf("expected no installations, got %#v", installations)
	}
}

func TestDetectReportsOnlyNonSecretAuthenticatedAccountMetadata(t *testing.T) {
	directory := t.TempDir()
	executable := filepath.Join(directory, "account-runtime")
	script := "#!/bin/sh\nif [ \"$1\" = login ]; then printf 'Logged in using Test Plan\\n'; else printf 'runtime 1.2.3\\n'; fi\n"
	if err := os.WriteFile(executable, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory)
	catalog, err := New([]Definition{{
		AdapterKey: "account_fixture", ProtocolVersion: "v1", ExecutableNames: []string{"account-runtime"},
		VersionArguments: []string{"--version"}, AccountArguments: []string{"login", "status"},
		AccountMarker: "Logged in using Test Plan", AccountMetadata: map[string]string{"authentication": "test_subscription"},
		MinimumVersion: "1.0.0", MaximumVersion: "1.9.99",
	}}, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	installation := catalog.Detect(context.Background())[0]
	if installation.HealthStatus != "available" || installation.AccountMetadata["authentication"] != "test_subscription" {
		t.Fatalf("unexpected account detection %#v", installation)
	}
}
