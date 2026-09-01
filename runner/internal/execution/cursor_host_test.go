//go:build darwin

package execution

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters"
	"github.com/glnarayanan/navishai/runner/internal/adapters/cursor"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/providerconfig"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
)

type fakeCursorHostSource struct {
	supported      bool
	executeCalls   int
	discoveryCalls int
	invocation     cursor.Invocation
}

func (source *fakeCursorHostSource) Supported() bool {
	return source.supported
}

func (source *fakeCursorHostSource) Execute(_ context.Context, invocation cursor.Invocation, emit func(protocol.CanonicalEvent) error) (cursor.Result, error) {
	source.executeCalls++
	source.invocation = invocation
	if err := emit(protocol.CanonicalEvent{EventType: "output.produced", Data: map[string]any{"text": runtimeTestSentinel}}); err != nil {
		return cursor.Result{}, err
	}
	if err := emit(protocol.CanonicalEvent{EventType: "run.completed", Data: map[string]any{"outcome": "completed"}}); err != nil {
		return cursor.Result{}, err
	}
	return cursor.Result{Status: "completed", Output: runtimeTestSentinel}, nil
}

func (source *fakeCursorHostSource) DiscoverModels(context.Context, string, string, string) ([]adapters.ModelOption, error) {
	source.discoveryCalls++
	return []adapters.ModelOption{{ID: "gpt-5.5", Label: "gpt-5.5"}, {ID: "composer-2.5", Label: "composer-2.5"}}, nil
}

func TestCursorHostUsesOneSourceForDiscoveryRuntimeTestAndExecution(t *testing.T) {
	registry, request, source, installation := cursorHostTestRegistry(t)
	discovery := registry.DiscoverModels(
		newHostModelsRequest(), workspaceOne, cursor.AdapterKey, protocol.ExecutionModeHostTrusted,
	)
	if discovery.Status != providerconfig.ModelDiscoveryAvailable || len(discovery.Models) != 2 {
		t.Fatalf("host Cursor discovery failed: %#v", discovery)
	}
	if source.discoveryCalls != 1 {
		t.Fatalf("host discovery bypassed the Cursor source: %d", source.discoveryCalls)
	}
	testResult, err := registry.TestRuntime(context.Background(), runtimecatalog.TestRequest{
		WorkspaceKey: workspaceOne, RequestID: workspaceTwo, DetectionKey: installation.DetectionKey,
		ExecutionMode: protocol.ExecutionModeHostTrusted, ConfigurationFingerprint: installation.ConfigurationFingerprint,
	})
	if err != nil || testResult.Status != "passed" {
		t.Fatalf("host Cursor runtime test failed: result=%#v err=%v", testResult, err)
	}
	if source.executeCalls != 1 {
		t.Fatalf("host runtime test bypassed the Cursor source: %d", source.executeCalls)
	}
	if err := registry.Execute(context.Background(), request, func(protocol.CanonicalEvent) error { return nil }); err != nil {
		t.Fatalf("host Cursor execution failed: %v", err)
	}
	if source.executeCalls != 2 || source.invocation.Executable != installation.ExecutablePath ||
		source.invocation.Admission.Routing.ExecutionMode != protocol.ExecutionModeHostTrusted {
		t.Fatalf("host execution did not use the exact source invocation: %#v", source.invocation)
	}
}

func TestCursorHostDeniesWithoutDeploymentOptInOrExactIdentity(t *testing.T) {
	registry, request, source, installation := cursorHostTestRegistry(t)
	registry.config.HostTrustedEnabled = false
	if err := registry.Execute(context.Background(), request, func(protocol.CanonicalEvent) error { return nil }); !errors.Is(err, ErrPolicyDenied) {
		t.Fatalf("host execution passed without deployment opt-in: %v", err)
	}
	if source.executeCalls != 0 {
		t.Fatalf("deployment gate reached the source: %d", source.executeCalls)
	}
	registry.config.HostTrustedEnabled = true
	request.Routing.ConfigurationFingerprint = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	if err := registry.Execute(context.Background(), request, func(protocol.CanonicalEvent) error { return nil }); !errors.Is(err, ErrPolicyDenied) {
		t.Fatalf("stale identity passed the host gate: %v", err)
	}
	if source.executeCalls != 0 {
		t.Fatalf("identity gate reached the source: %d", source.executeCalls)
	}
	_ = installation
}

func TestCursorHostRejectsStrongIsolationPolicy(t *testing.T) {
	registry, request, source, _ := cursorHostTestRegistry(t)
	request.Routing.IsolationPolicy = protocol.IsolationPolicyStrongRequired
	if err := registry.Execute(context.Background(), request, func(protocol.CanonicalEvent) error { return nil }); !errors.Is(err, ErrPolicyDenied) {
		t.Fatalf("strong-isolation policy was accepted by host Cursor: %v", err)
	}
	if source.executeCalls != 0 {
		t.Fatalf("policy gate reached the host source: %d", source.executeCalls)
	}
}

func TestManagedCatalogExposesHostModeOnlyForCursorSource(t *testing.T) {
	catalog := &ManagedCatalog{
		config:               Config{HostTrustedEnabled: true},
		supported:            func() bool { return false },
		hostTrustedSupported: func() bool { return true },
	}
	if modes := catalog.supportedExecutionModes(cursor.AdapterKey); len(modes) != 1 || modes[0] != protocol.ExecutionModeHostTrusted {
		t.Fatalf("unexpected Cursor host modes: %#v", modes)
	}
	if modes := catalog.supportedExecutionModes("codex_subscription"); len(modes) != 0 {
		t.Fatalf("non-Cursor host mode was exposed: %#v", modes)
	}
	catalog.hostTrustedSupported = func() bool { return false }
	if modes := catalog.supportedExecutionModes(cursor.AdapterKey); len(modes) != 0 {
		t.Fatalf("unsupported host source was exposed: %#v", modes)
	}
}

func cursorHostTestRegistry(t *testing.T) (*Registry, protocol.AdmissionRequest, *fakeCursorHostSource, runtimecatalog.Installation) {
	t.Helper()
	workRoot := t.TempDir()
	homeDir := t.TempDir()
	executable := filepath.Join(workRoot, "cursor-agent")
	if err := os.WriteFile(executable, []byte("cursor-host-test-runtime"), 0o700); err != nil {
		t.Fatal(err)
	}
	store, err := providerconfig.OpenStore("", testConfigurationIdentityKey)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Configure(workspaceOne, cursor.AdapterKey, "subscription", protocol.ExecutionModeHostTrusted, "", ""); err != nil {
		t.Fatal(err)
	}
	request := executionRequest(t)
	request.WorkspaceKey = workspaceOne
	request.Routing.AdapterKey = cursor.AdapterKey
	request.Routing.ExecutionMode = protocol.ExecutionModeHostTrusted
	request.Routing.IsolationPolicy = protocol.IsolationPolicyHostTrustedAllowed
	adapterConfig := AdapterConfig{
		Enabled: true, HomeDir: homeDir, EgressProfileKey: "model_api",
		Profiles: []string{request.Routing.ProfileKey}, Roles: []string{request.Agent.RoleKey},
		Tools:             append([]string(nil), request.Agent.AllowedTools...),
		DataClasses:       append([]string(nil), request.Routing.DataClasses...),
		MaxTimeoutSeconds: request.Agent.TimeoutSeconds, MaxSteps: request.Agent.MaxSteps,
		MaxToolCalls: request.Agent.MaxToolCalls, MaxInputUnits: request.Routing.MaxInputUnits,
		MaxOutputUnits: request.Routing.MaxOutputUnits,
	}
	supervisorConfig := SupervisorConfig{
		ApprovedExecutables: []string{executable},
		EgressProfiles:      []EgressProfileConfig{{Key: "model_api"}},
	}
	detectionKey := testDetectionKey(t, cursor.AdapterKey, executable)
	version := "cursor-agent 2026.08.11"
	model, fingerprint, err := AdapterConfigurationIdentityForRuntime(
		cursor.AdapterKey, adapterConfig, supervisorConfig, "subscription", "", testConfigurationIdentityKey,
		executable, detectionKey, version, protocol.ExecutionModeHostTrusted,
	)
	if err != nil {
		t.Fatal(err)
	}
	installation := runtimecatalog.Installation{
		DetectionKey: detectionKey, AdapterKey: cursor.AdapterKey, ProtocolVersion: protocol.Version,
		ExecutablePath: executable, ExecutableVersion: version,
		AccountMetadata: map[string]string{"authentication": "managed_on_runner"},
		Capabilities:    []string{runtimecatalog.RuntimeTestCapability, "acp", "structured_output"},
		Transport:       runtimecatalog.TransportManagedProcess, ExecutionMode: protocol.ExecutionModeHostTrusted,
		EffectiveModel: model, ConfigurationFingerprint: fingerprint,
		MinimumVersion: cursor.Definition().MinimumVersion, MaximumVersion: cursor.Definition().MaximumVersion,
		CompatibilityStatus: "compatible", HealthStatus: "available",
		CheckedAt: time.Now().UTC().Format(time.RFC3339Nano),
	}
	catalog, err := runtimecatalog.NewWithInstallations(nil, []runtimecatalog.Installation{installation}, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	source := &fakeCursorHostSource{supported: true}
	registry := &Registry{
		config: Config{
			WorkRoot: workRoot, Adapters: map[string]AdapterConfig{cursor.AdapterKey: adapterConfig},
			Supervisor: supervisorConfig, HostTrustedEnabled: true,
		},
		catalog: catalog, providers: store, configurationIdentityKey: testConfigurationIdentityKey,
		cursorHost: source, supported: func() bool { return false }, now: time.Now,
	}
	registry.execute = registry.Execute
	request.Routing.DetectionKey = detectionKey
	request.Routing.ConfigurationFingerprint = fingerprint
	request.Routing.EffectiveModel = model
	return registry, request, source, installation
}

func newHostModelsRequest() *http.Request {
	return &http.Request{}
}
