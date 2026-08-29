package execution

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
)

func TestRegistryExecutesConfiguredScriptedAdapterAndEnforcesPolicy(t *testing.T) {
	fixture := filepath.Join("..", "scripted", "testdata", "success.json")
	request := executionRequest(t)
	request.Routing.DetectionKey = ScriptedDetectionKey(fixture)
	config := Config{
		WorkRoot: t.TempDir(), Scripted: map[string]string{"workspace_default": fixture},
		Adapters: map[string]AdapterConfig{"scripted": {
			Enabled: true, Profiles: []string{"workspace_default"}, Roles: []string{request.Agent.RoleKey},
			Tools: request.Agent.AllowedTools, DataClasses: request.Routing.DataClasses,
			MaxTimeoutSeconds: 900, MaxSteps: 20, MaxToolCalls: 50,
			MaxInputUnits: 100_000, MaxOutputUnits: 25_000,
		}},
	}
	registry, err := NewRegistry(config, runtimecatalog.Empty(), func() time.Time {
		return time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)
	})
	if err != nil {
		t.Fatal(err)
	}
	events := []protocol.CanonicalEvent{}
	if err := registry.Execute(context.Background(), request, func(event protocol.CanonicalEvent) error {
		events = append(events, event)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if len(events) != 6 || events[0].EventType != "run.started" || events[len(events)-1].EventType != "run.completed" {
		t.Fatalf("unexpected scripted lifecycle: %#v", events)
	}

	request.Routing.DataClasses = append(request.Routing.DataClasses, "retrieved_memory")
	if err := registry.Execute(context.Background(), request, func(protocol.CanonicalEvent) error { return nil }); err != ErrPolicyDenied {
		t.Fatalf("expected policy denial, got %v", err)
	}
}

func TestRegistryDispatchesEachConfiguredLiveAdapter(t *testing.T) {
	request := executionRequest(t)
	for _, adapterKey := range []string{"codex_subscription", "claude_subscription", "grok_acp_subscription", "cursor_acp_subscription"} {
		t.Run(adapterKey, func(t *testing.T) {
			workRoot := t.TempDir()
			homeRoot := t.TempDir()
			executableRoot := t.TempDir()
			helperPath := testExecutable(t, executableRoot, "helper", "exit 0")
			executablePath := testExecutable(t, executableRoot, "approved", "exit 1")
			request := request
			request.Routing.AdapterKey = adapterKey
			request.Routing.DetectionKey = testDetectionKey(t, adapterKey, executablePath)
			installation := runtimecatalog.Installation{
				DetectionKey: request.Routing.DetectionKey, AdapterKey: adapterKey, ProtocolVersion: protocol.Version,
				ExecutablePath: executablePath, ExecutableVersion: "runtime 1.0.0",
				AccountMetadata: map[string]string{"authentication": "managed_on_runner"}, Capabilities: []string{"structured_output"},
				MinimumVersion: "1.0.0", MaximumVersion: "1.0.0", CompatibilityStatus: "compatible",
				HealthStatus: "available", CheckedAt: time.Now().UTC().Format(time.RFC3339Nano),
			}
			catalog, err := runtimecatalog.NewWithInstallations(nil, []runtimecatalog.Installation{installation}, time.Now)
			if err != nil {
				t.Fatal(err)
			}
			config := Config{
				WorkRoot: workRoot,
				Adapters: map[string]AdapterConfig{adapterKey: {
					Enabled: true, HomeDir: homeRoot, EgressProfileKey: "missing",
					Profiles: []string{request.Routing.ProfileKey}, Roles: []string{request.Agent.RoleKey},
					Tools: request.Agent.AllowedTools, DataClasses: request.Routing.DataClasses,
					MaxTimeoutSeconds: 900, MaxSteps: 20, MaxToolCalls: 50,
					MaxInputUnits: 100_000, MaxOutputUnits: 25_000,
				}},
				Supervisor: SupervisorConfig{
					HelperPath: helperPath, AllowedExecutableRoots: []string{executableRoot},
					ApprovedExecutables: []string{executablePath}, AllowedWorkingRoots: []string{workRoot},
					AllowedHomeRoots: []string{homeRoot}, RuntimeReadRoots: []string{"/usr"},
					Limits: SupervisorLimits{WallTimeSeconds: 1, CPUSeconds: 1, MemoryBytes: 32 * 1024 * 1024,
						OpenFiles: 3, Processes: 1, OutputBytes: 1024},
				},
			}
			registry, err := NewRegistry(config, catalog, time.Now)
			if err != nil {
				t.Fatal(err)
			}
			events := []protocol.CanonicalEvent{}
			err = registry.Execute(context.Background(), request, func(event protocol.CanonicalEvent) error {
				events = append(events, event)
				return nil
			})
			if errors.Is(err, ErrPolicyDenied) {
				t.Fatalf("adapter branch was not dispatched: %v", err)
			}
			if len(events) > 0 && (events[0].EventType != "run.started" || events[0].Data["adapter"] != adapterKey) {
				t.Fatalf("adapter branch emitted the wrong lifecycle: %#v", events)
			}
		})
	}
}

func testExecutable(t *testing.T, directory, name, command string) string {
	t.Helper()
	path := filepath.Join(directory, name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+command+"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	return path
}

func testDetectionKey(t *testing.T, adapterKey, path string) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	file, err := os.Open(resolved)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	digest := sha256.New()
	_, _ = digest.Write([]byte(adapterKey + "\x00" + resolved + "\x00"))
	if _, err := io.Copy(digest, file); err != nil {
		t.Fatal(err)
	}
	return hex.EncodeToString(digest.Sum(nil))
}

func executionRequest(t *testing.T) protocol.AdmissionRequest {
	t.Helper()
	body, err := os.ReadFile(filepath.Join("..", "..", "..", "test", "fixtures", "files", "runner_protocol", "v1", "admission_request.json"))
	if err != nil {
		t.Fatal(err)
	}
	request, err := protocol.DecodeAdmissionBytes(body)
	if err != nil {
		t.Fatal(err)
	}
	return request
}
