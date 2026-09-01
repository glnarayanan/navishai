package execution

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

func TestLoadConfigAcceptsExampleAndDecodesEgressNamespaces(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "ops", "runner", "execution.example.json"))
	if err != nil {
		t.Fatal(err)
	}
	data = []byte(strings.Replace(string(data), `"egress_profiles": []`, `"egress_profiles": [{
      "key": "codex",
      "executable": "/opt/navishai/runtimes/codex",
      "user_namespace_path": "/proc/123/ns/user",
      "network_namespace_path": "/proc/123/ns/net",
      "environment": {"HTTPS_PROXY": "http://proxy:8080"}
    }]`, 1))
	path := filepath.Join(t.TempDir(), "execution.json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	config, err := LoadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	profile := config.Supervisor.EgressProfiles[0]
	if profile.UserNamespacePath != "/proc/123/ns/user" || profile.NetworkNamespacePath != "/proc/123/ns/net" {
		t.Fatalf("snake-case namespace paths were not decoded: %#v", profile)
	}
}

func TestLoadConfigRejectsDuplicateKeysAndPolicyValues(t *testing.T) {
	example, err := os.ReadFile(filepath.Join("..", "..", "..", "ops", "runner", "execution.example.json"))
	if err != nil {
		t.Fatal(err)
	}
	for name, data := range map[string][]byte{
		"object key": []byte(`{"work_root":"/tmp","work_root":"/var/tmp"}`),
		"policy value": []byte(strings.Replace(
			string(example), `"profiles": ["workspace_default", "fast", "thorough"]`, `"profiles": ["fast", "fast"]`, 1,
		)),
	} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "execution.json")
			if err := os.WriteFile(path, data, 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := LoadConfig(path); err == nil {
				t.Fatal("invalid execution config was accepted")
			}
		})
	}
}

func TestLoadConfigAcceptsExplicitCursorModelOverride(t *testing.T) {
	example, err := os.ReadFile(filepath.Join("..", "..", "..", "ops", "runner", "execution.example.json"))
	if err != nil {
		t.Fatal(err)
	}
	data := []byte(strings.Replace(
		string(example),
		"\"home_dir\": \"/var/lib/navishai/runtime/cursor\",\n      \"model\": \"\"",
		"\"home_dir\": \"/var/lib/navishai/runtime/cursor\",\n      \"model\": \"gpt-5.5-medium\"", 1,
	))
	path := filepath.Join(t.TempDir(), "execution.json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	config, err := LoadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if config.Adapters[cursorSubscriptionAdapter].Model != "gpt-5.5-medium" {
		t.Fatalf("explicit Cursor model was not loaded: %#v", config.Adapters[cursorSubscriptionAdapter])
	}
}

func TestAdapterConfigurationIdentityIsStableAndMaterial(t *testing.T) {
	identityKey := []byte("runner-configuration-test-key-at-least-32-bytes")
	adapter := AdapterConfig{
		Enabled: true, HomeDir: "/runtime/codex", Model: "gpt-test", EgressProfileKey: "model_api",
		Profiles: []string{"thorough", "fast"}, Roles: []string{"support_investigator"},
		Tools: []string{"case_read"}, DataClasses: []string{"case_content"},
		MaxTimeoutSeconds: 60, MaxSteps: 1, MaxToolCalls: 0, MaxInputUnits: 1000, MaxOutputUnits: 100,
	}
	supervisor := SupervisorConfig{EgressProfiles: []EgressProfileConfig{{
		Key: "model_api", Executable: "/opt/navishai/runtimes/codex",
		UserNamespacePath: "/proc/10/ns/user", NetworkNamespacePath: "/proc/10/ns/net",
		Environment: map[string]string{"HTTPS_PROXY": "http://proxy.internal:8080", "SSL_CERT_FILE": "/etc/ssl/cert.pem"},
	}}}

	model, fingerprint, err := AdapterConfigurationIdentity("codex_subscription", adapter, supervisor, identityKey, protocol.ExecutionModeStrongIsolated)
	if err != nil {
		t.Fatal(err)
	}
	reordered := adapter
	reordered.Profiles = []string{"fast", "thorough"}
	modelAgain, fingerprintAgain, err := AdapterConfigurationIdentity("codex_subscription", reordered, supervisor, identityKey, protocol.ExecutionModeStrongIsolated)
	if err != nil {
		t.Fatal(err)
	}

	if model != "gpt-test" || modelAgain != model || len(fingerprint) != 64 || fingerprintAgain != fingerprint {
		t.Fatalf("configuration identity was not stable: model=%q fingerprint=%q repeated=%q", model, fingerprint, fingerprintAgain)
	}
	reorderedSupervisor := supervisor
	reorderedProfile := reorderedSupervisor.EgressProfiles[0]
	reorderedProfile.Environment = map[string]string{
		"SSL_CERT_FILE": "/etc/ssl/cert.pem", "HTTPS_PROXY": "http://proxy.internal:8080",
	}
	reorderedSupervisor.EgressProfiles = []EgressProfileConfig{reorderedProfile}
	_, reorderedEnvironmentFingerprint, err := AdapterConfigurationIdentity(
		"codex_subscription", adapter, reorderedSupervisor, identityKey, protocol.ExecutionModeStrongIsolated,
	)
	if err != nil {
		t.Fatal(err)
	}
	if reorderedEnvironmentFingerprint != fingerprint {
		t.Fatal("egress environment order changed the configuration fingerprint")
	}
	changed := adapter
	changed.Model = "gpt-other"
	_, changedFingerprint, err := AdapterConfigurationIdentity("codex_subscription", changed, supervisor, identityKey, protocol.ExecutionModeStrongIsolated)
	if err != nil {
		t.Fatal(err)
	}
	if changedFingerprint == fingerprint {
		t.Fatal("model change did not change the configuration fingerprint")
	}
	_, changedModeFingerprint, err := AdapterConfigurationIdentity(
		"codex_subscription", adapter, supervisor, identityKey, protocol.ExecutionModeHostTrusted,
	)
	if err != nil {
		t.Fatal(err)
	}
	if changedModeFingerprint == fingerprint {
		t.Fatal("execution mode change did not change the configuration fingerprint")
	}
	withoutModel := adapter
	withoutModel.Model = ""
	defaultModel, _, err := AdapterConfigurationIdentity("codex_subscription", withoutModel, supervisor, identityKey, protocol.ExecutionModeStrongIsolated)
	if err != nil {
		t.Fatal(err)
	}
	if defaultModel != "runtime_default" {
		t.Fatalf("expected runtime_default, got %q", defaultModel)
	}

	changedSupervisor := supervisor
	changedProfile := changedSupervisor.EgressProfiles[0]
	changedProfile.Environment = map[string]string{
		"HTTPS_PROXY": "http://proxy.next.internal:8080", "SSL_CERT_FILE": "/etc/ssl/cert.pem",
	}
	changedSupervisor.EgressProfiles = []EgressProfileConfig{changedProfile}
	_, changedEnvironmentFingerprint, err := AdapterConfigurationIdentity(
		"codex_subscription", adapter, changedSupervisor, identityKey, protocol.ExecutionModeStrongIsolated,
	)
	if err != nil {
		t.Fatal(err)
	}
	if changedEnvironmentFingerprint == fingerprint {
		t.Fatal("egress environment value change did not change the configuration fingerprint")
	}

	_, alternateKeyFingerprint, err := AdapterConfigurationIdentity(
		"codex_subscription", adapter, supervisor, []byte("alternate-configuration-key-at-least-32-bytes"), protocol.ExecutionModeStrongIsolated,
	)
	if err != nil {
		t.Fatal(err)
	}
	if alternateKeyFingerprint == fingerprint {
		t.Fatal("configuration fingerprint was not keyed")
	}
	if _, _, err := AdapterConfigurationIdentity("codex_subscription", adapter, supervisor, []byte("short"), protocol.ExecutionModeStrongIsolated); err == nil {
		t.Fatal("short configuration identity key was accepted")
	}
	if _, _, err := AdapterConfigurationIdentity("codex_subscription", adapter, supervisor, identityKey, ""); err == nil {
		t.Fatal("missing execution mode was accepted")
	}
}

func TestAdapterConfigurationIdentityBindsResolvedRuntimeEvidence(t *testing.T) {
	identityKey := []byte("runner-configuration-test-key-at-least-32-bytes")
	adapter := AdapterConfig{
		Enabled: true, HomeDir: "/runtime/codex", Model: "gpt-test", EgressProfileKey: "model_api",
		Profiles: []string{"workspace_default"}, Roles: []string{"support_investigator"},
		Tools: []string{"case_read"}, DataClasses: []string{"case_content"},
		MaxTimeoutSeconds: 60, MaxSteps: 1, MaxToolCalls: 0, MaxInputUnits: 1000, MaxOutputUnits: 100,
	}
	supervisor := SupervisorConfig{EgressProfiles: []EgressProfileConfig{{Key: "model_api", Executable: "/opt/navishai/egress", Environment: map[string]string{}}}}
	identity := func(current AdapterConfig, authMode, apiKey, path, detection, version string) (string, string, error) {
		return AdapterConfigurationIdentityForRuntime(
			"codex_subscription", current, supervisor, authMode, apiKey, identityKey,
			path, detection, version, protocol.ExecutionModeStrongIsolated,
		)
	}
	_, baseline, err := identity(adapter, "subscription", "", "/opt/navishai/runtimes/codex", strings.Repeat("a", 64), "codex 0.149.0")
	if err != nil {
		t.Fatal(err)
	}
	for name, evidence := range map[string][3]string{
		"resolved path":    {"/opt/navishai/runtimes/codex-next", strings.Repeat("a", 64), "codex 0.149.0"},
		"detection digest": {"/opt/navishai/runtimes/codex", strings.Repeat("b", 64), "codex 0.149.0"},
		"observed version": {"/opt/navishai/runtimes/codex", strings.Repeat("a", 64), "codex 0.150.0"},
	} {
		t.Run(name, func(t *testing.T) {
			_, changed, err := identity(adapter, "subscription", "", evidence[0], evidence[1], evidence[2])
			if err != nil {
				t.Fatal(err)
			}
			if changed == baseline {
				t.Fatalf("runtime evidence change did not invalidate fingerprint: %q", evidence)
			}
		})
	}
	_, repeated, err := identity(adapter, "subscription", "", "/opt/navishai/runtimes/codex", strings.Repeat("a", 64), "codex 0.149.0")
	if err != nil || repeated != baseline {
		t.Fatalf("same runtime evidence was not stable: %q %v", repeated, err)
	}
	if _, _, err := identity(adapter, "subscription", "", "/opt/navishai/runtimes/codex", strings.Repeat("a", 64), "development build"); err == nil {
		t.Fatal("unbounded observed version evidence was accepted")
	}
	_, authChanged, err := identity(adapter, "api_key", "", "/opt/navishai/runtimes/codex", strings.Repeat("a", 64), "codex 0.149.0")
	if err != nil {
		t.Fatal(err)
	}
	if authChanged == baseline {
		t.Fatal("authentication mode change did not invalidate fingerprint")
	}
	_, modeChanged, err := AdapterConfigurationIdentityForRuntime(
		"codex_subscription", adapter, supervisor, "subscription", "", identityKey,
		"/opt/navishai/runtimes/codex", strings.Repeat("a", 64), "codex 0.149.0", protocol.ExecutionModeHostTrusted,
	)
	if err != nil {
		t.Fatal(err)
	}
	if modeChanged == baseline {
		t.Fatal("runtime execution mode change did not invalidate fingerprint")
	}
	policyChanged := adapter
	policyChanged.MaxSteps++
	_, policyFingerprint, err := identity(policyChanged, "subscription", "", "/opt/navishai/runtimes/codex", strings.Repeat("a", 64), "codex 0.149.0")
	if err != nil {
		t.Fatal(err)
	}
	if policyFingerprint == baseline {
		t.Fatal("policy change did not invalidate fingerprint")
	}
}
