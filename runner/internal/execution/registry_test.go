package execution

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters/claude"
	"github.com/glnarayanan/navishai/runner/internal/adapters/codex"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/providerapi"
	"github.com/glnarayanan/navishai/runner/internal/providerconfig"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
	"github.com/glnarayanan/navishai/runner/internal/scripted"
)

var testConfigurationIdentityKey = []byte("runner-configuration-test-key-at-least-32-bytes")

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
	fingerprint, err := ScriptedConfigurationFingerprint(config, testConfigurationIdentityKey)
	if err != nil {
		t.Fatal(err)
	}
	request.Routing.ConfigurationFingerprint = fingerprint
	request.Routing.EffectiveModel = "deterministic_fixture"
	registry, err := NewRegistry(config, runtimecatalog.Empty(), testConfigurationIdentityKey, func() time.Time {
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

func TestScriptedCatalogIdentityMatchesExecutionAndInvalidatesChangedSymlink(t *testing.T) {
	directory := t.TempDir()
	fixturePath := filepath.Join("..", "scripted", "testdata", "success.json")
	fixture, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatal(err)
	}
	firstTarget := filepath.Join(directory, "fixture-first.json")
	secondTarget := filepath.Join(directory, "fixture-second.json")
	configuredPath := filepath.Join(directory, "configured.json")
	if err := os.WriteFile(firstTarget, fixture, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(secondTarget, fixture, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(firstTarget, configuredPath); err != nil {
		t.Fatal(err)
	}
	request := executionRequest(t)
	config := Config{
		WorkRoot: t.TempDir(), Scripted: map[string]string{"workspace_default": configuredPath},
		Adapters: map[string]AdapterConfig{"scripted": {
			Enabled: true, Profiles: []string{"workspace_default"}, Roles: []string{request.Agent.RoleKey},
			Tools: request.Agent.AllowedTools, DataClasses: request.Routing.DataClasses,
			MaxTimeoutSeconds: 900, MaxSteps: 20, MaxToolCalls: 50,
			MaxInputUnits: 100_000, MaxOutputUnits: 25_000,
		}},
	}
	installations, err := ScriptedInstallations(config, testConfigurationIdentityKey, time.Now())
	if err != nil || len(installations) != 1 {
		t.Fatalf("expected one catalog installation, installations=%#v err=%v", installations, err)
	}
	first := installations[0]
	if fingerprint, err := ScriptedConfigurationFingerprint(config, testConfigurationIdentityKey); err != nil || fingerprint != first.ConfigurationFingerprint {
		t.Fatalf("catalog and configured-path fingerprints diverged: %q %#v", fingerprint, err)
	}
	resolved, detectionKey, fingerprint, snapshot, err := scriptedRuntimeIdentity(config, testConfigurationIdentityKey, configuredPath)
	if err != nil || resolved != first.ExecutablePath || detectionKey != first.DetectionKey || fingerprint != first.ConfigurationFingerprint {
		t.Fatalf("runtime identity snapshot diverged from catalog: path=%q key=%q fingerprint=%q err=%v", resolved, detectionKey, fingerprint, err)
	}
	request.Routing.DetectionKey = first.DetectionKey
	request.Routing.ConfigurationFingerprint = first.ConfigurationFingerprint
	catalog, err := runtimecatalog.NewWithInstallations(nil, installations, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	registry, err := NewRegistry(config, catalog, testConfigurationIdentityKey, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	if err := registry.Execute(context.Background(), request, func(protocol.CanonicalEvent) error { return nil }); err != nil {
		t.Fatalf("catalog fingerprint was rejected by execution identity: %v", err)
	}
	if err := os.Remove(configuredPath); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(secondTarget, configuredPath); err != nil {
		t.Fatal(err)
	}
	snapshotResult, err := scripted.New(time.Now).Execute(context.Background(), request, snapshot, func(protocol.CanonicalEvent) error { return nil })
	if err != nil || snapshotResult.Status != scripted.Completed {
		t.Fatalf("validated scripted snapshot was not executable after path swap: result=%#v err=%v", snapshotResult, err)
	}
	installations, err = ScriptedInstallations(config, testConfigurationIdentityKey, time.Now())
	if err != nil || len(installations) != 1 {
		t.Fatalf("expected one rediscovered installation, installations=%#v err=%v", installations, err)
	}
	second := installations[0]
	if second.DetectionKey == first.DetectionKey || second.ConfigurationFingerprint == first.ConfigurationFingerprint {
		t.Fatal("symlink target change did not invalidate scripted identity")
	}
	if err := registry.Execute(context.Background(), request, func(protocol.CanonicalEvent) error { return nil }); err != ErrPolicyDenied {
		t.Fatalf("stale scripted identity was not denied after symlink change: %v", err)
	}
	if err := os.WriteFile(secondTarget, append(fixture, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
	updated, err := ScriptedInstallations(config, testConfigurationIdentityKey, time.Now())
	if err != nil || len(updated) != 1 {
		t.Fatalf("expected one content-change rediscovery, installations=%#v err=%v", updated, err)
	}
	if updated[0].DetectionKey == second.DetectionKey || updated[0].ConfigurationFingerprint == second.ConfigurationFingerprint {
		t.Fatal("scripted content change did not invalidate identity")
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
			request.Routing.ConfigurationFingerprint = strings.Repeat("a", 64)
			request.Routing.EffectiveModel = "runtime_default"
			installation := runtimecatalog.Installation{
				DetectionKey: request.Routing.DetectionKey, AdapterKey: adapterKey, ProtocolVersion: protocol.Version,
				ExecutablePath: executablePath, ExecutableVersion: "runtime 1.0.0",
				AccountMetadata: map[string]string{"authentication": "managed_on_runner"}, Capabilities: []string{"structured_output"},
				EffectiveModel: "runtime_default", ConfigurationFingerprint: strings.Repeat("a", 64),
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
			registry, err := NewRegistry(config, catalog, testConfigurationIdentityKey, time.Now)
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
			stale := request
			stale.Routing.ConfigurationFingerprint = strings.Repeat("f", 64)
			if err := registry.Execute(context.Background(), stale, func(protocol.CanonicalEvent) error { return nil }); !errors.Is(err, ErrPolicyDenied) {
				t.Fatalf("stale configuration fingerprint was not denied: %v", err)
			}
			stale = request
			stale.Routing.EffectiveModel = "changed-model"
			if err := registry.Execute(context.Background(), stale, func(protocol.CanonicalEvent) error { return nil }); !errors.Is(err, ErrPolicyDenied) {
				t.Fatalf("stale effective model was not denied: %v", err)
			}
		})
	}
}

func TestRuntimeTestEligibilityUsesOnlyTheDeclaredCapability(t *testing.T) {
	declared := runtimecatalog.Installation{
		AdapterKey: "scripted", Capabilities: []string{runtimecatalog.RuntimeTestCapability},
	}
	if !supportsRuntimeTest(declared) {
		t.Fatal("declared runtime-test capability was ignored because of the adapter name")
	}
	undeclared := runtimecatalog.Installation{AdapterKey: "codex_subscription", Capabilities: []string{"structured_output"}}
	if supportsRuntimeTest(undeclared) {
		t.Fatal("adapter name enabled runtime testing without the declared capability")
	}
}

func TestRuntimeTestOrchestratesSentinelAndFailsClosed(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	workRoot := t.TempDir()
	fixture, err := os.ReadFile(filepath.Join("..", "scripted", "testdata", "success.json"))
	if err != nil {
		t.Fatal(err)
	}
	executablePath := filepath.Join(t.TempDir(), "test-runtime.json")
	if err := os.WriteFile(executablePath, fixture, 0o700); err != nil {
		t.Fatal(err)
	}
	executablePath, err = filepath.EvalSymlinks(executablePath)
	if err != nil {
		t.Fatal(err)
	}
	adapter := AdapterConfig{
		Enabled: true, Profiles: []string{"workspace_default"}, Roles: []string{"support_investigator"},
		MaxTimeoutSeconds: 60, MaxSteps: 1, MaxToolCalls: 0, MaxInputUnits: 1_000, MaxOutputUnits: 100,
	}
	config := Config{
		WorkRoot: workRoot, Scripted: map[string]string{"workspace_default": executablePath},
		Adapters:   map[string]AdapterConfig{"scripted": adapter},
		Supervisor: SupervisorConfig{ApprovedExecutables: []string{executablePath}},
	}
	fingerprint, err := ScriptedConfigurationFingerprint(config, testConfigurationIdentityKey)
	if err != nil {
		t.Fatal(err)
	}
	model := "deterministic_fixture"
	detectionKey := testDetectionKey(t, "scripted", executablePath)
	installation := runtimecatalog.Installation{
		DetectionKey: detectionKey, AdapterKey: "scripted", ProtocolVersion: protocol.Version,
		ExecutablePath: executablePath, ExecutableVersion: "runtime 1.0.0",
		AccountMetadata: map[string]string{"authentication": "built_in"},
		Capabilities:    []string{runtimecatalog.RuntimeTestCapability}, EffectiveModel: model,
		ConfigurationFingerprint: fingerprint, MinimumVersion: "1.0.0", MaximumVersion: "1.0.0",
		CompatibilityStatus: "compatible", HealthStatus: "available", CheckedAt: now.Format(time.RFC3339Nano),
	}
	catalog, err := runtimecatalog.NewWithInstallations(nil, []runtimecatalog.Installation{installation}, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	registry, err := NewRegistry(config, catalog, testConfigurationIdentityKey, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	executions := 0
	registry.execute = func(_ context.Context, request protocol.AdmissionRequest, emit func(protocol.CanonicalEvent) error) error {
		executions++
		if !isRuntimeTestAdmission(request) {
			t.Fatal("runtime test did not use fixed admission")
		}
		for _, event := range []protocol.CanonicalEvent{
			{EventType: "output.produced", Data: map[string]any{"text": runtimeTestSentinel}},
			{EventType: "run.completed", Data: map[string]any{"outcome": "completed"}},
		} {
			if err := emit(event); err != nil {
				return err
			}
		}
		return nil
	}
	request := runtimecatalog.TestRequest{
		WorkspaceKey: "c9bb966b-1fe9-4304-bd51-404e4fd9a09c", RequestID: "3d07f334-88ef-4fe4-a640-421e3ba79921",
		DetectionKey: detectionKey, ConfigurationFingerprint: fingerprint,
	}
	result, err := registry.TestRuntime(context.Background(), request)
	if err != nil || result.Status != "passed" || executions != 1 {
		t.Fatalf("runtime test failed: result=%#v err=%v executions=%d", result, err, executions)
	}
	if _, err := os.Stat(filepath.Join(workRoot, request.RequestID)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("test workspace was not removed: %v", err)
	}

	stale := request
	stale.ConfigurationFingerprint = strings.Repeat("f", 64)
	if _, err := registry.TestRuntime(context.Background(), stale); !errors.Is(err, runtimecatalog.ErrTestConfigurationChanged) || executions != 1 {
		t.Fatalf("stale fingerprint did not fail closed: %v", err)
	}
	if err := os.Mkdir(filepath.Join(workRoot, request.RequestID), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := registry.TestRuntime(context.Background(), request); !errors.Is(err, ErrPolicyDenied) || executions != 1 {
		t.Fatalf("pre-existing work directory did not fail closed: %v", err)
	}
}

func TestRuntimeTestAdmissionCarriesOnlyFixedSentinelContextAndZeroTools(t *testing.T) {
	request := runtimecatalog.TestRequest{
		WorkspaceKey: "c9bb966b-1fe9-4304-bd51-404e4fd9a09c",
		RequestID:    "3d07f334-88ef-4fe4-a640-421e3ba79921",
		DetectionKey: strings.Repeat("a", 64), ConfigurationFingerprint: strings.Repeat("b", 64),
	}
	config := AdapterConfig{
		Profiles: []string{"workspace_default"}, Roles: []string{"support_investigator"},
		MaxTimeoutSeconds: 900, MaxInputUnits: 100_000, MaxOutputUnits: 25_000,
	}

	admission := runtimeTestAdmission(request, "codex_subscription", config, "gpt-test", strings.Repeat("b", 64))

	if err := admission.Validate(); err != nil {
		t.Fatal(err)
	}
	if !isRuntimeTestAdmission(admission) {
		t.Fatal("fixed admission was not recognized as a no-tools runtime test")
	}
	if len(admission.Agent.AllowedTools) != 0 || len(admission.Routing.DataClasses) != 0 ||
		admission.Agent.MaxToolCalls != 0 || admission.Agent.MaxSteps != 1 || admission.Agent.TimeoutSeconds != 30 ||
		admission.Routing.MaxInputUnits != 512 || admission.Routing.MaxOutputUnits != 32 ||
		admission.Task.ExpectedOutput != runtimeTestSentinel {
		t.Fatalf("runtime test admission was not tightly bounded: %#v", admission)
	}
	serialized, _ := json.Marshal(admission)
	for _, forbidden := range []string{"customer_identity", "retrieved_memory", "public_web_search", "case_content"} {
		if bytes.Contains(serialized, []byte(forbidden)) {
			t.Fatalf("runtime test admission exposed %q", forbidden)
		}
	}
}

func TestEvaluateRuntimeTestRequiresExactSentinelAndRejectsToolUse(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	events := []protocol.CanonicalEvent{
		{EventType: "output.produced", Data: map[string]any{"text": runtimeTestSentinel}},
		{EventType: "usage.observed", Data: map[string]any{"input_units": 12, "output_units": 3}},
		{EventType: "run.completed", Data: map[string]any{"outcome": "completed"}},
	}
	result := evaluateRuntimeTest(events, nil, "fixture-model", strings.Repeat("a", 64), now)
	if result.Status != "passed" || !result.UsageObserved || result.InputUnits != 12 || result.OutputUnits != 3 {
		t.Fatalf("exact sentinel did not pass: %#v", result)
	}

	events = append([]protocol.CanonicalEvent{{EventType: "tool.completed", Data: map[string]any{"tool": "shell", "result": "ok"}}}, events...)
	result = evaluateRuntimeTest(events, nil, "fixture-model", strings.Repeat("a", 64), now)
	if result.Status != "failed" || result.FailureCode != "prohibited_tool_use" {
		t.Fatalf("tool use was not rejected: %#v", result)
	}
}

func TestDirectProviderAPIExecutionUsesCanonicalEventsAndLeavesWorkRootUntouched(t *testing.T) {
	registry, request, client, workRoot := directProviderAPIRegistry(t, providerapi.GenerationResult{
		Text: runtimeTestSentinel, InputTokens: 8, OutputTokens: 3,
	}, nil)
	before, err := os.ReadDir(workRoot)
	if err != nil {
		t.Fatal(err)
	}
	events := []protocol.CanonicalEvent{}
	if err := registry.Execute(context.Background(), request, func(event protocol.CanonicalEvent) error {
		events = append(events, event)
		return nil
	}); err != nil {
		t.Fatalf("direct provider API execution failed: %v", err)
	}
	if client.generationCalls != 1 || client.adapter != codex.AdapterKey || client.apiKey != "sk-direct-provider-value" || client.model != request.Routing.EffectiveModel {
		t.Fatalf("unexpected direct provider API invocation: %#v", client)
	}
	if client.outputTokens != providerapi.MaxOutputTokens {
		t.Fatalf("provider API output ceiling was not clamped: got %d", client.outputTokens)
	}
	if len(events) != 4 || events[0].EventType != "run.started" || events[0].Data["scenario"] != "api_key" ||
		events[1].EventType != "output.produced" || events[2].EventType != "usage.observed" || events[3].EventType != "run.completed" {
		t.Fatalf("unexpected direct provider API lifecycle: %#v", events)
	}
	after, err := os.ReadDir(workRoot)
	if err != nil {
		t.Fatal(err)
	}
	if len(before) != len(after) {
		t.Fatalf("direct provider API execution touched work root: before=%#v after=%#v", before, after)
	}
}

func TestDirectProviderAPIRuntimeTestUsesSameGeneratePathAndExactSentinel(t *testing.T) {
	registry, request, client, workRoot := directProviderAPIRegistry(t, providerapi.GenerationResult{
		Text: runtimeTestSentinel, InputTokens: 2, OutputTokens: 1,
	}, nil)
	installations := registry.catalog.(*ManagedCatalog).apiKeyInstallations(workspaceOne)
	if len(installations) != 1 {
		t.Fatalf("direct provider API installation was not available: %#v", installations)
	}
	installation := installations[0]
	result, err := registry.TestRuntime(context.Background(), runtimecatalog.TestRequest{
		WorkspaceKey: workspaceOne, RequestID: request.RunID, DetectionKey: installation.DetectionKey,
		ConfigurationFingerprint: installation.ConfigurationFingerprint,
	})
	if err != nil || result.Status != "passed" || client.generationCalls != 1 {
		t.Fatalf("direct provider API runtime test failed: result=%#v err=%v calls=%d", result, err, client.generationCalls)
	}
	if _, err := os.Stat(filepath.Join(workRoot, request.RunID)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("direct provider API runtime test touched work root: %v", err)
	}
	client.generation = providerapi.GenerationResult{Text: "not-the-sentinel", InputTokens: 2, OutputTokens: 1}
	result, err = registry.TestRuntime(context.Background(), runtimecatalog.TestRequest{
		WorkspaceKey: workspaceOne, RequestID: request.RunID, DetectionKey: installation.DetectionKey,
		ConfigurationFingerprint: installation.ConfigurationFingerprint,
	})
	if err != nil || result.Status != "failed" || client.generationCalls != 2 {
		t.Fatalf("non-sentinel provider API runtime test did not fail: result=%#v err=%v calls=%d", result, err, client.generationCalls)
	}
}

func TestDirectProviderAPIRejectsToolsBeforeCallingProvider(t *testing.T) {
	registry, request, client, _ := directProviderAPIRegistry(t, providerapi.GenerationResult{
		Text: "should not be used", InputTokens: 1, OutputTokens: 1,
	}, nil)
	request.Agent.AllowedTools = []string{"case_read"}
	request.Agent.MaxToolCalls = 1
	if err := registry.Execute(context.Background(), request, func(protocol.CanonicalEvent) error { return nil }); !errors.Is(err, ErrPolicyDenied) {
		t.Fatalf("tool-enabled direct API request was not denied: %v", err)
	}
	if client.generationCalls != 0 {
		t.Fatalf("provider API was called for a tool-enabled request: %d", client.generationCalls)
	}
}

func TestDirectProviderAPIMapsTypedFailureWithoutProviderDetails(t *testing.T) {
	registry, request, client, _ := directProviderAPIRegistry(t, providerapi.GenerationResult{}, &providerapi.Error{Code: providerapi.CodeAuthentication, StatusCode: 401})
	events := []protocol.CanonicalEvent{}
	if err := registry.Execute(context.Background(), request, func(event protocol.CanonicalEvent) error {
		events = append(events, event)
		return nil
	}); err != nil {
		t.Fatalf("typed provider failure returned an execution error: %v", err)
	}
	if client.generationCalls != 1 || len(events) != 2 || events[1].EventType != "run.failed" || events[1].Data["code"] != "provider_api_failed" || events[1].Data["retryable"] != false {
		t.Fatalf("typed provider failure was not mapped safely: %#v", events)
	}
	encoded, _ := json.Marshal(events)
	if bytes.Contains(encoded, []byte("sk-direct-provider-value")) || bytes.Contains(encoded, []byte("401")) {
		t.Fatalf("provider failure event exposed secret/provider detail: %s", encoded)
	}
}

func TestSubscriptionRuntimeTestsKeepCLIInstallationSemantics(t *testing.T) {
	for _, adapterKey := range []string{codex.AdapterKey, claude.AdapterKey} {
		t.Run(adapterKey, func(t *testing.T) {
			store, err := providerconfig.OpenStore("", testConfigurationIdentityKey)
			if err != nil {
				t.Fatal(err)
			}
			model := "subscription-model"
			if _, err := store.Configure(workspaceOne, adapterKey, "subscription", model, ""); err != nil {
				t.Fatal(err)
			}
			workRoot := t.TempDir()
			home := t.TempDir()
			executable := testExecutable(t, t.TempDir(), "approved", "exit 0")
			request := executionRequest(t)
			request.WorkspaceKey = workspaceOne
			request.Routing.AdapterKey = adapterKey
			adapter := AdapterConfig{
				HomeDir: home, EgressProfileKey: "model_api", Profiles: []string{request.Routing.ProfileKey},
				Roles: []string{request.Agent.RoleKey}, DataClasses: append([]string(nil), request.Routing.DataClasses...),
				MaxTimeoutSeconds: request.Agent.TimeoutSeconds, MaxSteps: request.Agent.MaxSteps, MaxToolCalls: request.Agent.MaxToolCalls,
				MaxInputUnits: request.Routing.MaxInputUnits, MaxOutputUnits: request.Routing.MaxOutputUnits,
			}
			supervisorConfig := SupervisorConfig{
				ApprovedExecutables: []string{executable}, EgressProfiles: []EgressProfileConfig{{Key: "model_api"}},
			}
			detectionKey := testDetectionKey(t, adapterKey, executable)
			_, fingerprint, err := AdapterConfigurationIdentityForRuntime(
				adapterKey, adapter, supervisorConfig, "subscription", "", testConfigurationIdentityKey,
				executable, detectionKey, "runtime 1.0.0",
			)
			if err != nil {
				t.Fatal(err)
			}
			installation := runtimecatalog.Installation{
				DetectionKey: detectionKey, AdapterKey: adapterKey, ProtocolVersion: protocol.Version,
				ExecutablePath: executable, ExecutableVersion: "runtime 1.0.0",
				AccountMetadata: map[string]string{"authentication": "managed_on_runner"},
				Capabilities:    []string{runtimecatalog.RuntimeTestCapability, "structured_output"}, EffectiveModel: model,
				ConfigurationFingerprint: fingerprint, MinimumVersion: "1.0.0", MaximumVersion: "1.0.0",
				CompatibilityStatus: "compatible", HealthStatus: "available", CheckedAt: time.Now().UTC().Format(time.RFC3339Nano),
			}
			catalog, err := runtimecatalog.NewWithInstallations(nil, []runtimecatalog.Installation{installation}, time.Now)
			if err != nil {
				t.Fatal(err)
			}
			client := &fakeProviderAPI{}
			registry := &Registry{
				config:  Config{WorkRoot: workRoot, Adapters: map[string]AdapterConfig{adapterKey: adapter}, Supervisor: supervisorConfig},
				catalog: catalog, providers: store, providerAPI: client, configurationIdentityKey: testConfigurationIdentityKey, now: time.Now,
			}
			executed := false
			registry.execute = func(_ context.Context, admission protocol.AdmissionRequest, emit func(protocol.CanonicalEvent) error) error {
				executed = true
				if isDirectProviderAPIInstallation(installation, providerconfig.Connection{AuthMode: "subscription", Model: model}) {
					t.Fatal("subscription installation was treated as built-in provider API")
				}
				for _, event := range []protocol.CanonicalEvent{
					{EventType: "output.produced", Data: map[string]any{"text": runtimeTestSentinel}},
					{EventType: "usage.observed", Data: map[string]any{"input_units": 1, "output_units": 1}},
					{EventType: "run.completed", Data: map[string]any{"outcome": "completed"}},
				} {
					if err := emit(event); err != nil {
						return err
					}
				}
				return nil
			}
			result, err := registry.TestRuntime(context.Background(), runtimecatalog.TestRequest{
				WorkspaceKey: workspaceOne, RequestID: request.RunID, DetectionKey: detectionKey, ConfigurationFingerprint: fingerprint,
			})
			if err != nil || result.Status != "passed" || !executed || client.generationCalls != 0 {
				t.Fatalf("subscription runtime test did not preserve process path: result=%#v err=%v executed=%t api_calls=%d", result, err, executed, client.generationCalls)
			}
		})
	}
}

func directProviderAPIRegistry(t *testing.T, generation providerapi.GenerationResult, generationErr error) (*Registry, protocol.AdmissionRequest, *fakeProviderAPI, string) {
	t.Helper()
	store, err := providerconfig.OpenStore("", testConfigurationIdentityKey)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Configure(workspaceOne, codex.AdapterKey, "api_key", "future-direct-model", "sk-direct-provider-value"); err != nil {
		t.Fatal(err)
	}
	request := executionRequest(t)
	request.WorkspaceKey = workspaceOne
	request.Routing.AdapterKey = codex.AdapterKey
	request.Agent.AllowedTools = nil
	request.Agent.MaxToolCalls = 0
	workRoot := t.TempDir()
	config := Config{
		WorkRoot: workRoot,
		Adapters: map[string]AdapterConfig{codex.AdapterKey: {
			Profiles: []string{request.Routing.ProfileKey}, Roles: []string{request.Agent.RoleKey},
			Tools: []string{}, DataClasses: append([]string(nil), request.Routing.DataClasses...),
			MaxTimeoutSeconds: request.Agent.TimeoutSeconds, MaxSteps: request.Agent.MaxSteps, MaxToolCalls: 0,
			MaxInputUnits: request.Routing.MaxInputUnits, MaxOutputUnits: providerapi.MaxOutputTokens + 100,
		}},
	}
	catalog, err := NewManagedCatalog(config, store, testConfigurationIdentityKey, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	installations := catalog.apiKeyInstallations(workspaceOne)
	if len(installations) != 1 {
		t.Fatalf("direct provider API fixture produced %d installations: %#v", len(installations), installations)
	}
	request.Routing.DetectionKey = installations[0].DetectionKey
	request.Routing.ConfigurationFingerprint = installations[0].ConfigurationFingerprint
	request.Routing.EffectiveModel = installations[0].EffectiveModel
	request.Routing.MaxOutputUnits = providerapi.MaxOutputTokens + 100
	client := &fakeProviderAPI{generation: generation, generationErr: generationErr}
	registry := &Registry{
		config: config, catalog: catalog, providers: store, configurationIdentityKey: testConfigurationIdentityKey,
		providerAPI: client, now: time.Now,
	}
	registry.execute = registry.Execute
	return registry, request, client, workRoot
}

func testExecutable(t *testing.T, directory, name, command string) string {
	t.Helper()
	path := filepath.Join(directory, name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+command+"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	return resolved
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
