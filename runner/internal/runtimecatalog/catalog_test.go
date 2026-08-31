package runtimecatalog

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
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
		EffectiveModel: "fixture-model", ConfigurationFingerprint: strings.Repeat("a", 64),
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
	resolvedExecutable, err := filepath.EvalSymlinks(executable)
	if err != nil {
		t.Fatal(err)
	}
	if installation.ExecutablePath != resolvedExecutable || installation.ExecutableVersion != "fixture 2.4.1" ||
		installation.AdapterKey != "fixture" || installation.HealthStatus != "available" ||
		installation.EffectiveModel != "fixture-model" || installation.ConfigurationFingerprint != strings.Repeat("a", 64) ||
		installation.CompatibilityStatus != "compatible" ||
		installation.AccountMetadata["authentication"] != "managed_on_runner" || len(installation.DetectionKey) != 64 {
		t.Fatalf("unexpected installation %#v", installation)
	}
}

func TestCompatibilityAcceptsFutureVersionsWithBoundedEvidence(t *testing.T) {
	status, reason := compatibilityFor("fixture 3.0.0", "2.0.0", "2.9.99")
	if status != "compatible" || reason != "" {
		t.Fatalf("expected a compatible result, got %q %q", status, reason)
	}
	status, reason = compatibilityFor("development build", "2.0.0", "2.9.99")
	if status != "unknown" || reason == "" {
		t.Fatalf("expected an unknown result, got %q %q", status, reason)
	}
	status, reason = compatibilityFor(strings.Repeat("3", maxVersionBytes+1), "2.0.0", "2.9.99")
	if status != "unknown" || reason == "" {
		t.Fatalf("expected oversized evidence to remain unknown, got %q %q", status, reason)
	}
}

func TestValidObservedVersionRejectsControlAndUnboundedEvidence(t *testing.T) {
	tests := []struct {
		name  string
		value string
		valid bool
	}{
		{name: "future semantic version", value: "provider 99.1.2 (stable)", valid: true},
		{name: "carriage return", value: "provider 1.2.3\r", valid: false},
		{name: "line feed", value: "provider 1.2.3\n", valid: false},
		{name: "null", value: "provider 1.2.3\x00", valid: false},
		{name: "ascii control", value: "provider 1.2.3\x1b", valid: false},
		{name: "oversized", value: strings.Repeat("x", maxVersionBytes+1), valid: false},
		{name: "no semantic version", value: "development build", valid: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := ValidObservedVersion(test.value); got != test.valid {
				t.Fatalf("ValidObservedVersion(%q) = %v, want %v", test.value, got, test.valid)
			}
		})
	}
}

func TestDetectBindsConfigurationIdentityToRuntimeEvidence(t *testing.T) {
	directory := t.TempDir()
	executable := filepath.Join(directory, "fixture-runtime")
	if err := os.WriteFile(executable, []byte("#!/bin/sh\nprintf 'fixture 3.0.0\\n'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory)
	identityCalls := 0
	catalog, err := New([]Definition{{
		AdapterKey: "fixture", ProtocolVersion: "v1", ExecutableNames: []string{"fixture-runtime"},
		VersionArguments: []string{"--version"}, Capabilities: []string{"structured_output"},
		EffectiveModel: "fixture-model", ConfigurationFingerprint: strings.Repeat("a", 64),
		MinimumVersion: "2.0.0", MaximumVersion: "2.9.99",
		ConfigurationIdentity: func(path, key, version string) (string, string, error) {
			identityCalls++
			if path == "" || len(key) != 64 || version != "fixture 3.0.0" {
				t.Fatalf("identity callback received incomplete evidence: %q %q %q", path, key, version)
			}
			return "fixture-model-v2", strings.Repeat("b", 64), nil
		},
	}}, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	installations := catalog.Detect(context.Background())
	if len(installations) != 1 || identityCalls != 1 {
		t.Fatalf("expected one identity-bound installation, calls=%d installations=%#v", identityCalls, installations)
	}
	if installations[0].EffectiveModel != "fixture-model-v2" || installations[0].ConfigurationFingerprint != strings.Repeat("b", 64) {
		t.Fatalf("runtime identity was not applied: %#v", installations[0])
	}
}

func TestDetectOmitsUnregisteredAndMissingExecutables(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	catalog, err := New([]Definition{{
		AdapterKey: "fixture", ProtocolVersion: "v1", ExecutableNames: []string{"not-installed"},
		VersionArguments: []string{"--version"},
		EffectiveModel:   "fixture-model", ConfigurationFingerprint: strings.Repeat("a", 64),
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
		EffectiveModel: "fixture-model", ConfigurationFingerprint: strings.Repeat("a", 64),
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

func TestDetectUsesAdapterAccountValidatorAndNamedEnvironment(t *testing.T) {
	directory := t.TempDir()
	executable := filepath.Join(directory, "json-runtime")
	script := "#!/bin/sh\nif [ \"$1\" = auth ] && [ \"$ACCOUNT_HOME\" = /approved/account ]; then printf '{\"authenticated\":true}\\n'; else printf 'runtime 2.1.241\\n'; fi\n"
	if err := os.WriteFile(executable, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory)
	t.Setenv("ACCOUNT_HOME", "/approved/account")
	catalog, err := New([]Definition{{
		AdapterKey: "json_fixture", ProtocolVersion: "v1", ExecutableNames: []string{"json-runtime"},
		VersionArguments: []string{"--version"}, AccountArguments: []string{"auth", "status"},
		AccountValidator:   func(output string) bool { return output == `{"authenticated":true}` },
		AccountEnvironment: []string{"ACCOUNT_HOME"}, AccountMetadata: map[string]string{"authentication": "test_subscription"},
		EffectiveModel: "fixture-model", ConfigurationFingerprint: strings.Repeat("a", 64),
		MinimumVersion: "2.1.200", MaximumVersion: "2.1.299",
	}}, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	installation := catalog.Detect(context.Background())[0]
	if installation.HealthStatus != "available" || installation.AccountMetadata["authentication"] != "test_subscription" {
		t.Fatalf("unexpected account detection %#v", installation)
	}
}

func TestNewRejectsAmbiguousAccountValidatorsAndUnsafeEnvironmentNames(t *testing.T) {
	base := Definition{
		AdapterKey: "fixture", ProtocolVersion: "v1", ExecutableNames: []string{"fixture"},
		VersionArguments: []string{"--version"}, AccountArguments: []string{"auth"},
		AccountMetadata: map[string]string{"authentication": "fixture"},
		EffectiveModel:  "fixture-model", ConfigurationFingerprint: strings.Repeat("a", 64),
	}
	definitions := []Definition{
		base,
		base,
		base,
	}
	definitions[0].AccountMarker = "authenticated"
	definitions[0].AccountValidator = func(string) bool { return true }
	definitions[1].AccountValidator = func(string) bool { return true }
	definitions[1].AccountEnvironment = []string{"NAVISHAI_SECRET"}
	definitions[2].AccountValidator = func(string) bool { return true }
	definitions[2].AccountEnvironment = []string{"ACCOUNT_HOME", "ACCOUNT_HOME"}
	for _, definition := range definitions {
		if _, err := New([]Definition{definition}, time.Now); !errors.Is(err, ErrInvalidDefinition) {
			t.Fatalf("expected invalid definition error for %#v, got %v", definition, err)
		}
	}
}

func TestNewRejectsInvalidStaticInstallation(t *testing.T) {
	installation := Installation{
		DetectionKey: strings.Repeat("a", 64), AdapterKey: "scripted", ProtocolVersion: "v1",
		ExecutablePath: "/tmp/fixture.json", ExecutableVersion: "scripted 1.0.0",
		AccountMetadata: map[string]string{"authentication": "built_in"}, Capabilities: []string{"tool_calling"},
		EffectiveModel: "deterministic_fixture", ConfigurationFingerprint: strings.Repeat("b", 64),
		MinimumVersion: "1.0.0", MaximumVersion: "1.0.0", CompatibilityStatus: "compatible",
		HealthStatus: "available", CheckedAt: "not-a-time",
	}
	if _, err := NewWithInstallations(nil, []Installation{installation}, time.Now); !errors.Is(err, ErrInvalidDefinition) {
		t.Fatalf("expected invalid static installation rejection, got %v", err)
	}
}

func TestResolveApprovedRejectsChangedBytesBeforeRunningProbe(t *testing.T) {
	directory := t.TempDir()
	executable := filepath.Join(directory, "fixture-runtime")
	marker := filepath.Join(directory, "probed")
	if err := os.WriteFile(executable, []byte("#!/bin/sh\nprintf 'fixture 1.0.0\\n'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory)
	catalog, err := New([]Definition{{
		AdapterKey: "fixture", ProtocolVersion: "v1", ExecutableNames: []string{"fixture-runtime"},
		VersionArguments: []string{"--version"}, Capabilities: []string{"structured_output"},
		EffectiveModel: "fixture-model", ConfigurationFingerprint: strings.Repeat("a", 64),
		MinimumVersion: "1.0.0", MaximumVersion: "1.0.0",
	}}, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	approvedKey := detectionKey("fixture", executable)
	changed := "#!/bin/sh\ntouch " + marker + "\nprintf 'fixture 1.0.0\\n'\n"
	if err := os.WriteFile(executable, []byte(changed), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, ok := catalog.ResolveApproved(context.Background(), approvedKey, []string{executable}); ok {
		t.Fatal("changed executable was resolved")
	}
	if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("changed executable ran before its detection key was checked: %v", err)
	}
}

func TestDetectApprovedDoesNotProbeUnapprovedExecutableOrExposeCredentialHome(t *testing.T) {
	directory := t.TempDir()
	credentialHome := filepath.Join(directory, "credential-home")
	if err := os.Mkdir(credentialHome, 0o700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(directory, "unapproved-probe")
	unapproved := filepath.Join(directory, "fixture-runtime")
	script := "#!/bin/sh\nprintf '%s|%s' \"$HOME\" \"$ACCOUNT_HOME\" > " + marker + "\nprintf 'fixture 1.0.0\\n'\n"
	if err := os.WriteFile(unapproved, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	approved := filepath.Join(directory, "approved-runtime")
	if err := os.WriteFile(approved, []byte("#!/bin/sh\nprintf 'approved 1.0.0\\n'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory)
	t.Setenv("ACCOUNT_HOME", credentialHome)
	catalog, err := New([]Definition{{
		AdapterKey: "fixture", ProtocolVersion: "v1", ExecutableNames: []string{"fixture-runtime"},
		VersionArguments: []string{"--version"}, AccountArguments: []string{"auth", "status"},
		AccountMarker: "authenticated", AccountEnvironment: []string{"ACCOUNT_HOME"}, AccountHome: credentialHome,
		AccountMetadata: map[string]string{"authentication": "fixture_subscription"},
		Capabilities:    []string{"structured_output"}, EffectiveModel: "fixture-model",
		ConfigurationFingerprint: strings.Repeat("a", 64), MinimumVersion: "1.0.0", MaximumVersion: "1.0.0",
	}}, time.Now)
	if err != nil {
		t.Fatal(err)
	}

	if installations := catalog.DetectApproved(context.Background(), []string{approved}); len(installations) != 0 {
		t.Fatalf("unapproved runtime was detected: %#v", installations)
	}
	if contents, err := os.ReadFile(marker); err == nil {
		t.Fatalf("unapproved runtime executed and observed credential paths: %q", contents)
	} else if !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
}
