package execution

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters/codex"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/providerconfig"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
)

func TestManagedCatalogActivatesDisabledTemplateWithoutRestartAndSkipsSubscriptionProbeForAPIKey(t *testing.T) {
	directory := t.TempDir()
	home := filepath.Join(directory, "codex-home")
	if err := os.Mkdir(home, 0o700); err != nil {
		t.Fatal(err)
	}
	executable := filepath.Join(directory, "codex")
	script := "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'codex 0.149.0'; exit 0; fi\nexit 73\n"
	if err := os.WriteFile(executable, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory)
	store, err := providerconfig.OpenStore("", []byte("managed-catalog-provider-secret-at-least-32-bytes"))
	if err != nil {
		t.Fatal(err)
	}
	workspaceKey := "c9bb966b-1fe9-4304-bd51-404e4fd9a09c"
	if _, err := store.Configure(workspaceKey, codex.AdapterKey, "api_key", "gpt-test", "sk-test-secret"); err != nil {
		t.Fatal(err)
	}
	config := managedCatalogTestConfig(home, executable)
	if config.Adapters[codex.AdapterKey].Enabled {
		t.Fatal("test requires a disabled bootstrap template")
	}
	catalog, err := NewManagedCatalog(config, store, []byte("managed-catalog-identity-secret-at-least-32-bytes"), func() time.Time {
		return time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	})
	if err != nil {
		t.Fatal(err)
	}
	installations := catalog.DetectWorkspace(context.Background(), workspaceKey)
	if len(installations) != 1 || installations[0].AdapterKey != codex.AdapterKey ||
		installations[0].HealthStatus != "available" || installations[0].EffectiveModel != "gpt-test" {
		t.Fatalf("configured disabled template was not activated: %#v", installations)
	}
	if other := catalog.DetectWorkspace(context.Background(), "3d07f334-88ef-4fe4-a640-421e3ba79921"); len(other) != 0 {
		t.Fatalf("managed connection leaked across workspaces: %#v", other)
	}
}

func TestManagedCatalogProbesConfiguredSubscriptionHome(t *testing.T) {
	directory := t.TempDir()
	home := filepath.Join(directory, "codex-home")
	if err := os.Mkdir(home, 0o700); err != nil {
		t.Fatal(err)
	}
	executable := filepath.Join(directory, "codex")
	script := "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'codex 0.149.0'; exit 0; fi\nif [ \"$1\" = \"login\" ] && [ \"$2\" = \"status\" ] && [ \"$CODEX_HOME\" = '" + home + "' ] && [ \"$HOME\" = '" + home + "' ]; then echo 'Logged in using ChatGPT'; exit 0; fi\nexit 74\n"
	if err := os.WriteFile(executable, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory)
	store, _ := providerconfig.OpenStore("", []byte("managed-catalog-provider-secret-at-least-32-bytes"))
	workspaceKey := "c9bb966b-1fe9-4304-bd51-404e4fd9a09c"
	if _, err := store.Configure(workspaceKey, codex.AdapterKey, "subscription", "", ""); err != nil {
		t.Fatal(err)
	}
	catalog, err := NewManagedCatalog(managedCatalogTestConfig(home, executable), store,
		[]byte("managed-catalog-identity-secret-at-least-32-bytes"), time.Now)
	if err != nil {
		t.Fatal(err)
	}
	installations := catalog.DetectWorkspace(context.Background(), workspaceKey)
	if len(installations) != 1 || installations[0].HealthStatus != "available" ||
		installations[0].AccountMetadata["authentication"] != "chatgpt_subscription" {
		t.Fatalf("configured credential home was not used by account probe: %#v", installations)
	}
}

func TestManagedCatalogDoesNotProbeUnapprovedRuntime(t *testing.T) {
	directory := t.TempDir()
	home := filepath.Join(directory, "codex-home")
	if err := os.Mkdir(home, 0o700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(directory, "unapproved-probe")
	unapproved := filepath.Join(directory, "codex")
	script := "#!/bin/sh\nprintf '%s|%s' \"$HOME\" \"$CODEX_HOME\" > " + marker + "\nprintf 'codex 0.149.0\\n'\n"
	if err := os.WriteFile(unapproved, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	approved := filepath.Join(directory, "approved-runtime")
	if err := os.WriteFile(approved, []byte("#!/bin/sh\nprintf 'approved 1.0.0\\n'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory)
	store, err := providerconfig.OpenStore("", []byte("managed-catalog-provider-secret-at-least-32-bytes"))
	if err != nil {
		t.Fatal(err)
	}
	workspaceKey := "c9bb966b-1fe9-4304-bd51-404e4fd9a09c"
	if _, err := store.Configure(workspaceKey, codex.AdapterKey, "subscription", "", ""); err != nil {
		t.Fatal(err)
	}
	catalog, err := NewManagedCatalog(managedCatalogTestConfig(home, approved), store,
		[]byte("managed-catalog-identity-secret-at-least-32-bytes"), time.Now)
	if err != nil {
		t.Fatal(err)
	}

	if installations := catalog.DetectWorkspace(context.Background(), workspaceKey); len(installations) != 0 {
		t.Fatalf("unapproved runtime was detected: %#v", installations)
	}
	if contents, err := os.ReadFile(marker); err == nil {
		t.Fatalf("unapproved runtime executed and observed credential paths: %q", contents)
	} else if !os.IsNotExist(err) {
		t.Fatal(err)
	}
}

func TestManagedConfigureDetectAndRuntimeTestUseSameWorkspaceConfigurationWithoutRestart(t *testing.T) {
	directory := t.TempDir()
	home := filepath.Join(directory, "codex-home")
	workRoot := filepath.Join(directory, "work")
	if err := os.Mkdir(home, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(workRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	executable := filepath.Join(directory, "codex")
	if err := os.WriteFile(executable, []byte("#!/bin/sh\necho 'codex 0.149.0'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory)
	store, _ := providerconfig.OpenStore("", []byte("managed-catalog-provider-secret-at-least-32-bytes"))
	workspaceKey := "c9bb966b-1fe9-4304-bd51-404e4fd9a09c"
	if _, err := store.Configure(workspaceKey, codex.AdapterKey, "api_key", "gpt-test", "sk-test-secret"); err != nil {
		t.Fatal(err)
	}
	config := managedCatalogTestConfig(home, executable)
	config.WorkRoot = workRoot
	identityKey := []byte("managed-catalog-identity-secret-at-least-32-bytes")
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	catalog, err := NewManagedCatalog(config, store, identityKey, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	installations := catalog.DetectWorkspace(context.Background(), workspaceKey)
	if len(installations) != 1 {
		t.Fatalf("configured runtime was not detected: %#v", installations)
	}
	registry := &Registry{
		config: config, catalog: catalog, providers: store,
		configurationIdentityKey: identityKey, now: func() time.Time { return now },
	}
	registry.execute = func(_ context.Context, request protocol.AdmissionRequest, emit func(protocol.CanonicalEvent) error) error {
		for index, event := range []struct {
			typeName string
			data     map[string]any
		}{
			{"run.started", map[string]any{"adapter": codex.AdapterKey, "scenario": "subscription", "attempt": 1}},
			{"output.produced", map[string]any{"text": runtimeTestSentinel}},
			{"run.completed", map[string]any{"outcome": "completed"}},
		} {
			canonical, err := protocol.NewCanonicalEvent(request.RunID, index+2, event.typeName, now, event.data)
			if err != nil {
				return err
			}
			if err := emit(canonical); err != nil {
				return err
			}
		}
		return nil
	}
	result, err := registry.TestRuntime(context.Background(), runtimecatalog.TestRequest{
		WorkspaceKey: workspaceKey, RequestID: "3d07f334-88ef-4fe4-a640-421e3ba79921",
		DetectionKey: installations[0].DetectionKey, ConfigurationFingerprint: installations[0].ConfigurationFingerprint,
	})
	if err != nil || result.Status != "passed" || result.EffectiveModel != "gpt-test" {
		t.Fatalf("configured runtime test failed: result=%#v err=%v", result, err)
	}
}

func managedCatalogTestConfig(home, executable string) Config {
	return Config{
		WorkRoot: filepath.Dir(home),
		Adapters: map[string]AdapterConfig{codex.AdapterKey: {
			Enabled: false, HomeDir: home, Model: "legacy-model", EgressProfileKey: "model_api",
			Profiles: []string{"workspace_default"}, Roles: []string{"support_investigator"},
			DataClasses: []string{"case_content"}, MaxTimeoutSeconds: 300, MaxSteps: 10,
			MaxToolCalls: 20, MaxInputUnits: 100_000, MaxOutputUnits: 25_000,
		}},
		Supervisor: SupervisorConfig{
			ApprovedExecutables: []string{executable},
			EgressProfiles:      []EgressProfileConfig{{Key: "model_api", Executable: executable, Environment: map[string]string{}}},
		},
	}
}

func TestManagedConfigurationFingerprintChangesWithCredentialWithoutExposingIt(t *testing.T) {
	config := managedCatalogTestConfig("/runtime/codex", "/usr/bin/codex")
	adapter := config.Adapters[codex.AdapterKey]
	key := []byte("managed-catalog-identity-secret-at-least-32-bytes")
	_, first, err := adapterConfigurationIdentityFor(codex.AdapterKey, adapter, config.Supervisor, "api_key", "sk-first-secret", key)
	if err != nil {
		t.Fatal(err)
	}
	_, second, err := adapterConfigurationIdentityFor(codex.AdapterKey, adapter, config.Supervisor, "api_key", "sk-second-secret", key)
	if err != nil {
		t.Fatal(err)
	}
	if first == second || strings.Contains(first, "sk-") || strings.Contains(second, "sk-") {
		t.Fatalf("credential fingerprint did not bind secret safely: %q %q", first, second)
	}
}
