//go:build darwin

package execution

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters"
	"github.com/glnarayanan/navishai/runner/internal/adapters/codex"
	"github.com/glnarayanan/navishai/runner/internal/adapters/cursor"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/providerconfig"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
)

type fakeCursorHostSource struct {
	supported           bool
	executeCalls        int
	discoveryCalls      int
	codexExecuteCalls   int
	codexDiscoveryCalls int
	invocation          cursor.Invocation
	codexInvocation     codex.Invocation
}

type unscopedWorkspaceCatalog struct {
	installation runtimecatalog.Installation
}

func (catalog unscopedWorkspaceCatalog) DetectWorkspace(context.Context, string) []runtimecatalog.Installation {
	return []runtimecatalog.Installation{catalog.installation}
}

func (catalog unscopedWorkspaceCatalog) ResolveApprovedWorkspace(context.Context, string, string, []string) (runtimecatalog.Installation, bool) {
	return catalog.installation, true
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

func (source *fakeCursorHostSource) ExecuteCodex(_ context.Context, invocation codex.Invocation, emit func(protocol.CanonicalEvent) error) (codex.Result, error) {
	source.codexExecuteCalls++
	source.codexInvocation = invocation
	if err := emit(protocol.CanonicalEvent{EventType: "output.produced", Data: map[string]any{"text": runtimeTestSentinel}}); err != nil {
		return codex.Result{}, err
	}
	if err := emit(protocol.CanonicalEvent{EventType: "run.completed", Data: map[string]any{"outcome": "completed"}}); err != nil {
		return codex.Result{}, err
	}
	return codex.Result{Status: "completed", Output: runtimeTestSentinel}, nil
}

func (source *fakeCursorHostSource) DiscoverCodexModels(context.Context, string, string, string) ([]adapters.ModelOption, error) {
	source.codexDiscoveryCalls++
	return []adapters.ModelOption{{ID: "gpt-5.6-sol", Label: "GPT-5.6-Sol"}}, nil
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

func TestCursorHostModelDiscoveryFailsClosedWithoutTargetedCatalog(t *testing.T) {
	registry, _, source, installation := cursorHostTestRegistry(t)
	registry.catalog = unscopedWorkspaceCatalog{installation: installation}
	result := registry.DiscoverModels(newHostModelsRequest(), workspaceOne, cursor.AdapterKey, protocol.ExecutionModeHostTrusted)
	if result.Status != providerconfig.ModelDiscoveryFailed || source.discoveryCalls != 0 {
		t.Fatalf("host model discovery did not fail closed without targeted detection: result=%#v calls=%d", result, source.discoveryCalls)
	}
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

func TestManagedCatalogExposesHostModeForCodexAndCursorSources(t *testing.T) {
	catalog := &ManagedCatalog{
		config:               Config{HostTrustedEnabled: true},
		supported:            func() bool { return false },
		hostTrustedSupported: func() bool { return true },
	}
	if modes := catalog.supportedExecutionModes(cursor.AdapterKey); len(modes) != 1 || modes[0] != protocol.ExecutionModeHostTrusted {
		t.Fatalf("unexpected Cursor host modes: %#v", modes)
	}
	if modes := catalog.supportedExecutionModes(codex.AdapterKey); !slices.Contains(modes, protocol.ExecutionModeHostTrusted) || slices.Contains(modes, protocol.ExecutionModeStrongIsolated) {
		t.Fatalf("unexpected Codex host modes: %#v", modes)
	}
	for _, adapterKey := range []string{"claude_subscription", "grok_acp_subscription"} {
		if modes := catalog.supportedExecutionModes(adapterKey); slices.Contains(modes, protocol.ExecutionModeHostTrusted) {
			t.Fatalf("unsupported host adapter was exposed: adapter=%q modes=%#v", adapterKey, modes)
		}
	}
	catalog.hostTrustedSupported = func() bool { return false }
	if modes := catalog.supportedExecutionModes(cursor.AdapterKey); len(modes) != 0 {
		t.Fatalf("unsupported host source was exposed: %#v", modes)
	}
}

func TestCodexHostUsesOneSourceForDiscoveryRuntimeTestAndExecution(t *testing.T) {
	registry, request, source, installation := codexHostTestRegistry(t)
	discovery := registry.DiscoverModels(newHostModelsRequest(), workspaceOne, codex.AdapterKey, protocol.ExecutionModeHostTrusted)
	if discovery.Status != providerconfig.ModelDiscoveryAvailable || len(discovery.Models) != 1 || source.codexDiscoveryCalls != 1 {
		t.Fatalf("host Codex discovery failed: result=%#v source=%#v", discovery, source)
	}
	testResult, err := registry.TestRuntime(context.Background(), runtimecatalog.TestRequest{
		WorkspaceKey: workspaceOne, RequestID: workspaceTwo, DetectionKey: installation.DetectionKey,
		ExecutionMode: protocol.ExecutionModeHostTrusted, ConfigurationFingerprint: installation.ConfigurationFingerprint,
	})
	if err != nil || testResult.Status != "passed" {
		t.Fatalf("host Codex runtime test failed: result=%#v err=%v", testResult, err)
	}
	if source.codexExecuteCalls != 1 || !source.codexInvocation.DisableTools {
		t.Fatalf("runtime test did not use the constrained Codex source: calls=%d invocation=%#v", source.codexExecuteCalls, source.codexInvocation)
	}
	if err := registry.Execute(context.Background(), request, func(protocol.CanonicalEvent) error { return nil }); err != nil {
		t.Fatalf("host Codex execution failed: %v", err)
	}
	if source.codexExecuteCalls != 2 || source.codexInvocation.Executable != installation.ExecutablePath ||
		source.codexInvocation.Admission.Routing.ExecutionMode != protocol.ExecutionModeHostTrusted || !source.codexInvocation.DisableTools {
		t.Fatalf("host Codex execution did not use the exact source invocation: %#v", source.codexInvocation)
	}
}

func TestHostExecutionDeniesOccupiedRunDirectoryWithoutDeletingIt(t *testing.T) {
	tests := []struct {
		name          string
		buildRegistry func(*testing.T) (*Registry, protocol.AdmissionRequest, *fakeCursorHostSource, runtimecatalog.Installation)
		executeCalls  func(*fakeCursorHostSource) int
	}{
		{
			name:          "cursor",
			buildRegistry: cursorHostTestRegistry,
			executeCalls:  func(source *fakeCursorHostSource) int { return source.executeCalls },
		},
		{
			name:          "codex",
			buildRegistry: codexHostTestRegistry,
			executeCalls:  func(source *fakeCursorHostSource) int { return source.codexExecuteCalls },
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			controlRegistry, controlRequest, controlSource, _ := test.buildRegistry(t)
			if err := controlRegistry.Execute(context.Background(), controlRequest, func(protocol.CanonicalEvent) error { return nil }); err != nil {
				t.Fatalf("valid host execution control failed: %v", err)
			}
			if calls := test.executeCalls(controlSource); calls != 1 {
				t.Fatalf("valid host execution control did not reach the source: %d", calls)
			}

			registry, request, source, _ := test.buildRegistry(t)
			workingDirectory := filepath.Join(registry.config.WorkRoot, request.RunID)
			if err := os.Mkdir(workingDirectory, 0o700); err != nil {
				t.Fatal(err)
			}
			marker := filepath.Join(workingDirectory, "existing")
			if err := os.WriteFile(marker, []byte("preserve"), 0o600); err != nil {
				t.Fatal(err)
			}

			err := registry.Execute(context.Background(), request, func(protocol.CanonicalEvent) error { return nil })
			if !errors.Is(err, ErrPolicyDenied) {
				t.Fatalf("occupied run directory was not denied: %v", err)
			}
			if calls := test.executeCalls(source); calls != 0 {
				t.Fatalf("occupied run directory reached the host source: %d", calls)
			}
			if contents, err := os.ReadFile(marker); err != nil || string(contents) != "preserve" {
				t.Fatalf("occupied run directory was changed: contents=%q err=%v", contents, err)
			}
		})
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
	executable, err := filepath.EvalSymlinks(executable)
	if err != nil {
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

func codexHostTestRegistry(t *testing.T) (*Registry, protocol.AdmissionRequest, *fakeCursorHostSource, runtimecatalog.Installation) {
	t.Helper()
	workRoot := t.TempDir()
	homeDir := t.TempDir()
	executable := filepath.Join(workRoot, "codex")
	if err := os.WriteFile(executable, []byte("codex-host-test-runtime"), 0o700); err != nil {
		t.Fatal(err)
	}
	executable, err := filepath.EvalSymlinks(executable)
	if err != nil {
		t.Fatal(err)
	}
	store, err := providerconfig.OpenStore("", testConfigurationIdentityKey)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Configure(workspaceOne, codex.AdapterKey, "subscription", protocol.ExecutionModeHostTrusted, "gpt-5.6-sol", ""); err != nil {
		t.Fatal(err)
	}
	request := executionRequest(t)
	request.WorkspaceKey = workspaceOne
	request.Routing.AdapterKey = codex.AdapterKey
	request.Routing.ExecutionMode = protocol.ExecutionModeHostTrusted
	request.Routing.IsolationPolicy = protocol.IsolationPolicyHostTrustedAllowed
	adapterConfig := AdapterConfig{
		Enabled: true, HomeDir: homeDir, EgressProfileKey: "model_api", Model: "gpt-5.6-sol",
		Profiles: []string{request.Routing.ProfileKey}, Roles: []string{request.Agent.RoleKey},
		Tools: append([]string(nil), request.Agent.AllowedTools...), DataClasses: append([]string(nil), request.Routing.DataClasses...),
		MaxTimeoutSeconds: request.Agent.TimeoutSeconds, MaxSteps: request.Agent.MaxSteps,
		MaxToolCalls: request.Agent.MaxToolCalls, MaxInputUnits: request.Routing.MaxInputUnits,
		MaxOutputUnits: request.Routing.MaxOutputUnits,
	}
	supervisorConfig := SupervisorConfig{
		ApprovedExecutables: []string{executable},
		EgressProfiles:      []EgressProfileConfig{{Key: "model_api"}},
	}
	detectionKey := testDetectionKey(t, codex.AdapterKey, executable)
	version := "codex 0.250.0"
	model, fingerprint, err := AdapterConfigurationIdentityForRuntime(
		codex.AdapterKey, adapterConfig, supervisorConfig, "subscription", "", testConfigurationIdentityKey,
		executable, detectionKey, version, protocol.ExecutionModeHostTrusted,
	)
	if err != nil {
		t.Fatal(err)
	}
	installation := runtimecatalog.Installation{
		DetectionKey: detectionKey, AdapterKey: codex.AdapterKey, ProtocolVersion: protocol.Version,
		ExecutablePath: executable, ExecutableVersion: version,
		AccountMetadata: map[string]string{"authentication": "chatgpt_subscription"},
		Capabilities:    []string{runtimecatalog.RuntimeTestCapability, "structured_output", "tool_calling"},
		Transport:       runtimecatalog.TransportManagedProcess, ExecutionMode: protocol.ExecutionModeHostTrusted,
		EffectiveModel: model, ConfigurationFingerprint: fingerprint,
		MinimumVersion: codex.Definition().MinimumVersion, MaximumVersion: codex.Definition().MaximumVersion,
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
			WorkRoot: workRoot, Adapters: map[string]AdapterConfig{codex.AdapterKey: adapterConfig},
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
