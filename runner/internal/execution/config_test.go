package execution

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
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
		"Cursor model": []byte(strings.Replace(
			string(example),
			"\"home_dir\": \"/var/lib/navishai/runtime/cursor\",\n      \"model\": \"\"",
			"\"home_dir\": \"/var/lib/navishai/runtime/cursor\",\n      \"model\": \"cursor-model\"", 1,
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

	model, fingerprint, err := AdapterConfigurationIdentity("codex_subscription", adapter, supervisor, identityKey)
	if err != nil {
		t.Fatal(err)
	}
	reordered := adapter
	reordered.Profiles = []string{"fast", "thorough"}
	modelAgain, fingerprintAgain, err := AdapterConfigurationIdentity("codex_subscription", reordered, supervisor, identityKey)
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
		"codex_subscription", adapter, reorderedSupervisor, identityKey,
	)
	if err != nil {
		t.Fatal(err)
	}
	if reorderedEnvironmentFingerprint != fingerprint {
		t.Fatal("egress environment order changed the configuration fingerprint")
	}
	changed := adapter
	changed.Model = "gpt-other"
	_, changedFingerprint, err := AdapterConfigurationIdentity("codex_subscription", changed, supervisor, identityKey)
	if err != nil {
		t.Fatal(err)
	}
	if changedFingerprint == fingerprint {
		t.Fatal("model change did not change the configuration fingerprint")
	}
	withoutModel := adapter
	withoutModel.Model = ""
	defaultModel, _, err := AdapterConfigurationIdentity("codex_subscription", withoutModel, supervisor, identityKey)
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
		"codex_subscription", adapter, changedSupervisor, identityKey,
	)
	if err != nil {
		t.Fatal(err)
	}
	if changedEnvironmentFingerprint == fingerprint {
		t.Fatal("egress environment value change did not change the configuration fingerprint")
	}

	_, alternateKeyFingerprint, err := AdapterConfigurationIdentity(
		"codex_subscription", adapter, supervisor, []byte("alternate-configuration-key-at-least-32-bytes"),
	)
	if err != nil {
		t.Fatal(err)
	}
	if alternateKeyFingerprint == fingerprint {
		t.Fatal("configuration fingerprint was not keyed")
	}
	if _, _, err := AdapterConfigurationIdentity("codex_subscription", adapter, supervisor, []byte("short")); err == nil {
		t.Fatal("short configuration identity key was accepted")
	}
}
