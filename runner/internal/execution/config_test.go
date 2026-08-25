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
		"object key":   []byte(`{"work_root":"/tmp","work_root":"/var/tmp"}`),
		"policy value": []byte(strings.Replace(string(example), `"profiles": ["workspace_default", "fast", "thorough"]`, `"profiles": ["fast", "fast"]`, 1)),
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
