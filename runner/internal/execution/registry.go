package execution

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/providerapi"
	"github.com/glnarayanan/navishai/runner/internal/providerconfig"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
	"github.com/glnarayanan/navishai/runner/internal/scripted"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

var ErrPolicyDenied = errors.New("runner execution policy denied the request")

const runtimeTestSentinel = "NAVISHAI_RUNTIME_TEST_OK"

type Registry struct {
	config                   Config
	catalog                  runtimecatalog.WorkspaceCatalog
	providers                *providerconfig.Store
	configurationIdentityKey []byte
	processRunner            adapters.ProcessRunner
	cursorHost               cursorHostSource
	providerAPI              ProviderAPI
	supported                func() bool
	now                      func() time.Time
	execute                  func(context.Context, protocol.AdmissionRequest, func(protocol.CanonicalEvent) error) error
}

func NewRegistry(config Config, catalog runtimecatalog.WorkspaceCatalog, configurationIdentityKey []byte, now func() time.Time) (*Registry, error) {
	return newRegistry(config, catalog, nil, configurationIdentityKey, now)
}

func NewRegistryWithProviders(config Config, catalog runtimecatalog.WorkspaceCatalog, providers *providerconfig.Store, configurationIdentityKey []byte, now func() time.Time) (*Registry, error) {
	if providers == nil {
		return nil, ErrPolicyDenied
	}
	return newRegistry(config, catalog, providers, configurationIdentityKey, now)
}

func newRegistry(config Config, catalog runtimecatalog.WorkspaceCatalog, providers *providerconfig.Store, configurationIdentityKey []byte, now func() time.Time) (*Registry, error) {
	if config.WorkRoot == "" || catalog == nil || protocol.ValidateSecret(configurationIdentityKey) != nil {
		return nil, ErrPolicyDenied
	}
	if now == nil {
		now = time.Now
	}
	workRoot, err := filepath.EvalSymlinks(config.WorkRoot)
	if errors.Is(err, os.ErrNotExist) {
		if err := os.MkdirAll(config.WorkRoot, 0o700); err != nil {
			return nil, err
		}
		workRoot, err = filepath.EvalSymlinks(config.WorkRoot)
	}
	if err != nil || !filepath.IsAbs(workRoot) {
		return nil, ErrPolicyDenied
	}
	config.WorkRoot = workRoot
	var processSupervisor *supervisor.Supervisor
	if (providers == nil && anyLegacyLiveAdapter(config.Adapters)) || (providers != nil && anyManagedAdapterTemplate(config)) {
		processSupervisor, err = supervisor.New(config.Supervisor.build())
		if err != nil {
			return nil, fmt.Errorf("configure execution supervisor: %w", err)
		}
	}
	registry := &Registry{
		config: config, catalog: catalog, providers: providers,
		configurationIdentityKey: append([]byte(nil), configurationIdentityKey...),
		processRunner:            processSupervisor, cursorHost: newCursorHostSource(now), providerAPI: providerapi.New(),
		supported: supervisor.Supported, now: now,
	}
	registry.execute = registry.Execute
	return registry, nil
}

func (registry *Registry) Execute(ctx context.Context, request protocol.AdmissionRequest, emit func(protocol.CanonicalEvent) error) error {
	if request.Validate() != nil || emit == nil {
		return ErrPolicyDenied
	}
	if request.Routing.AdapterKey == "scripted" {
		if !boundedExecutionBoundary(request) {
			return ErrPolicyDenied
		}
		return registry.executeScripted(ctx, request, emit)
	}
	if registry.providers != nil {
		if connection, configured := registry.providers.Get(request.WorkspaceKey, request.Routing.AdapterKey); configured {
			if definition, ok := providerconfig.Lookup(request.Routing.AdapterKey); ok && definition.RequiresModel(connection.AuthMode) && connection.Model == "" {
				return ErrPolicyDenied
			}
			if connection.AuthMode == "api_key" {
				if isDirectProviderAPIAdapter(request.Routing.AdapterKey) {
					if connection.ExecutionMode != request.Routing.ExecutionMode || !boundedExecutionBoundary(request) {
						return ErrPolicyDenied
					}
					return registry.executeProviderAPIRequest(ctx, request, connection, emit)
				}
				return ErrPolicyDenied
			}
			if connection.AuthMode == "subscription" && connection.ExecutionMode == protocol.ExecutionModeHostTrusted {
				switch request.Routing.AdapterKey {
				case codexSubscriptionAdapter:
					return registry.executeCodexHost(ctx, request, connection, emit)
				case cursorSubscriptionAdapter:
					return registry.executeCursorHost(ctx, request, connection, emit)
				default:
					return ErrPolicyDenied
				}
			}
		}
	}
	// Subscription and other process transports remain unavailable. Do not
	// let a signed request select a stronger-looking boundary than the runner
	// can actually enforce for that process.
	return ErrPolicyDenied
}

func (registry *Registry) TestRuntime(ctx context.Context, request runtimecatalog.TestRequest) (runtimecatalog.TestResult, error) {
	installation, ok := registry.catalog.ResolveApprovedWorkspace(ctx, request.WorkspaceKey, request.DetectionKey, registry.config.Supervisor.ApprovedExecutables)
	if !ok || !supportsRuntimeTest(installation) ||
		installation.ExecutionMode != request.ExecutionMode || request.ExecutionMode == "" ||
		installation.ConfigurationFingerprint != request.ConfigurationFingerprint {
		return runtimecatalog.TestResult{}, runtimecatalog.ErrTestConfigurationChanged
	}
	var adapterConfig AdapterConfig
	authMode, apiKey := "", ""
	directProviderAPI := false
	var connection providerconfig.Connection
	if registry.providers != nil && installation.AdapterKey != "scripted" {
		connection, ok = registry.providers.Get(request.WorkspaceKey, installation.AdapterKey)
		if !ok {
			return runtimecatalog.TestResult{}, runtimecatalog.ErrTestConfigurationChanged
		}
		if definition, found := providerconfig.Lookup(installation.AdapterKey); found && definition.RequiresModel(connection.AuthMode) && connection.Model == "" {
			return runtimecatalog.TestResult{}, runtimecatalog.ErrTestConfigurationChanged
		}
		authMode, apiKey = connection.AuthMode, connection.APIKey
		directProviderAPI = isDirectProviderAPIInstallation(installation, connection)
	}
	if isDirectProviderAPIAdapter(installation.AdapterKey) {
		if authMode == "api_key" && !directProviderAPI {
			return runtimecatalog.TestResult{}, runtimecatalog.ErrTestConfigurationChanged
		}
		if authMode != "api_key" && installation.Transport == runtimecatalog.TransportBuiltInHTTPS {
			return runtimecatalog.TestResult{}, runtimecatalog.ErrTestConfigurationChanged
		}
	}
	executionMode, isolationPolicy, transportKnown := runtimeTestExecutionBoundary(installation, directProviderAPI)
	if !transportKnown {
		return runtimecatalog.TestResult{}, ErrPolicyDenied
	}
	if installation.AdapterKey == "scripted" {
		adapterConfig, ok = registry.config.Adapters[installation.AdapterKey]
		ok = ok && adapterConfig.Enabled
	} else if directProviderAPI {
		if connection.AuthMode != "api_key" {
			return runtimecatalog.TestResult{}, runtimecatalog.ErrTestConfigurationChanged
		}
		adapterConfig, ok = registry.config.Adapters[installation.AdapterKey]
		adapterConfig.Model = connection.Model
	} else if isHostTrustedSubscriptionAdapter(installation.AdapterKey) && executionMode == protocol.ExecutionModeHostTrusted {
		if connection.AuthMode != "subscription" || connection.ExecutionMode != protocol.ExecutionModeHostTrusted ||
			registry.cursorHost == nil || !registry.cursorHost.Supported() || !registry.config.HostTrustedEnabled {
			return runtimecatalog.TestResult{}, ErrPolicyDenied
		}
		if installation.AdapterKey == codexSubscriptionAdapter {
			if _, ok := registry.cursorHost.(codexHostSource); !ok {
				return runtimecatalog.TestResult{}, ErrPolicyDenied
			}
		}
		adapterConfig, ok = registry.config.Adapters[installation.AdapterKey]
		adapterConfig.Model = connection.Model
	}
	if !ok || len(adapterConfig.Profiles) == 0 || len(adapterConfig.Roles) == 0 {
		return runtimecatalog.TestResult{}, runtimecatalog.ErrTestConfigurationChanged
	}
	model, fingerprint, err := registry.runtimeTestConfiguration(request.WorkspaceKey, installation, adapterConfig, authMode, apiKey, executionMode)
	if err != nil || model != installation.EffectiveModel || fingerprint != request.ConfigurationFingerprint {
		return runtimecatalog.TestResult{}, runtimecatalog.ErrTestConfigurationChanged
	}
	admission := runtimeTestAdmission(request, installation.AdapterKey, adapterConfig, model, fingerprint, executionMode, isolationPolicy)
	if admission.Validate() != nil {
		return runtimecatalog.TestResult{}, ErrPolicyDenied
	}
	if !directProviderAPI {
		testWorkingDirectory := filepath.Join(registry.config.WorkRoot, admission.RunID)
		if _, err := os.Lstat(testWorkingDirectory); !errors.Is(err, os.ErrNotExist) {
			return runtimecatalog.TestResult{}, ErrPolicyDenied
		}
		defer os.RemoveAll(testWorkingDirectory)
	}
	events := []protocol.CanonicalEvent{}
	executeErr := registry.execute(ctx, admission, func(event protocol.CanonicalEvent) error {
		events = append(events, event)
		return nil
	})
	return evaluateRuntimeTest(events, executeErr, executionMode, model, fingerprint, registry.now()), nil
}

func (registry *Registry) runtimeTestConfiguration(workspaceKey string, installation runtimecatalog.Installation, adapterConfig AdapterConfig, authMode, apiKey, executionMode string) (string, string, error) {
	if installation.AdapterKey == "scripted" {
		if executionMode != protocol.ExecutionModeBounded {
			return "", "", runtimecatalog.ErrTestConfigurationChanged
		}
		_, detectionKey, fingerprint, _, err := scriptedRuntimeIdentity(
			registry.config, registry.configurationIdentityKey, installation.ExecutablePath,
		)
		if err == nil && detectionKey != installation.DetectionKey {
			return "", "", runtimecatalog.ErrTestConfigurationChanged
		}
		return "deterministic_fixture", fingerprint, err
	}
	if authMode == "api_key" && isDirectProviderAPIInstallation(installation, providerconfig.Connection{
		AuthMode: authMode, ExecutionMode: executionMode, Model: adapterConfig.Model, APIKey: apiKey,
	}) {
		return providerAPIConfigurationIdentity(workspaceKey, installation.AdapterKey, adapterConfig, providerconfig.Connection{
			AuthMode: authMode, ExecutionMode: executionMode, Model: adapterConfig.Model, APIKey: apiKey,
		}, registry.configurationIdentityKey)
	}
	if isHostTrustedSubscriptionAdapter(installation.AdapterKey) && authMode == "subscription" && executionMode == protocol.ExecutionModeHostTrusted &&
		installation.Transport == runtimecatalog.TransportManagedProcess && installation.ExecutionMode == protocol.ExecutionModeHostTrusted {
		return AdapterConfigurationIdentityForRuntime(
			installation.AdapterKey, adapterConfig, registry.config.Supervisor, authMode, "", registry.configurationIdentityKey,
			installation.ExecutablePath, installation.DetectionKey, installation.ExecutableVersion, executionMode,
		)
	}
	return "", "", ErrPolicyDenied
}

func (registry *Registry) effectiveAdapter(workspaceKey, adapterKey string) (AdapterConfig, map[string]string, bool) {
	adapter, ok := registry.config.Adapters[adapterKey]
	if !ok || (registry.providers == nil && !adapter.Enabled) ||
		(registry.providers != nil && !managedAdapterTemplateValid(registry.config, adapterKey, adapter)) {
		return AdapterConfig{}, nil, false
	}
	credentials := make(map[string]string)
	if registry.providers == nil {
		return adapter, credentials, true
	}
	connection, configured := registry.providers.Get(workspaceKey, adapterKey)
	if !configured {
		return AdapterConfig{}, nil, false
	}
	adapter.Model = connection.Model
	if connection.AuthMode == "api_key" {
		definition, found := providerconfig.Lookup(adapterKey)
		if !found || definition.CredentialEnv == "" || connection.APIKey == "" {
			return AdapterConfig{}, nil, false
		}
		credentials[definition.CredentialEnv] = connection.APIKey
	}
	return adapter, credentials, true
}

func runtimeTestExecutionBoundary(installation runtimecatalog.Installation, directProviderAPI bool) (string, string, bool) {
	if installation.AdapterKey == "scripted" || directProviderAPI {
		if installation.ExecutionMode != protocol.ExecutionModeBounded {
			return "", "", false
		}
		return installation.ExecutionMode, protocol.IsolationPolicyStrongRequired, true
	}
	if isHostTrustedSubscriptionAdapter(installation.AdapterKey) && installation.Transport == runtimecatalog.TransportManagedProcess &&
		installation.ExecutionMode == protocol.ExecutionModeHostTrusted {
		return installation.ExecutionMode, protocol.IsolationPolicyHostTrustedAllowed, true
	}
	return "", "", false
}

func boundedExecutionBoundary(request protocol.AdmissionRequest) bool {
	return request.Routing.ExecutionMode == protocol.ExecutionModeBounded &&
		request.Routing.IsolationPolicy == protocol.IsolationPolicyStrongRequired
}

func runtimeTestAdmission(request runtimecatalog.TestRequest, adapterKey string, config AdapterConfig, model, fingerprint, executionMode, isolationPolicy string) protocol.AdmissionRequest {
	timeout := min(config.MaxTimeoutSeconds, 30)
	return protocol.AdmissionRequest{
		ProtocolVersion: protocol.AdmissionVersion,
		RunID:           request.RequestID,
		IdempotencyKey:  "runtime-test-" + request.RequestID,
		WorkspaceKey:    request.WorkspaceKey,
		Task: protocol.Task{
			TaskKey: request.RequestID, Attempt: 1, Title: "Verify configured provider runtime",
			InputContext:   "This fixed connectivity check contains no customer or workspace data.",
			ExpectedOutput: runtimeTestSentinel,
		},
		Agent: protocol.AgentPolicy{
			RoleKey: config.Roles[0], PolicyVersion: 1,
			Instructions: "Return exactly the expected sentinel. Do not use tools, files, memory, web access, or other context.",
			AllowedTools: []string{}, RuntimeProfileKey: config.Profiles[0], FallbackProfileKeys: []string{},
			TimeoutSeconds: timeout, MaxSteps: 1, MaxToolCalls: 0, ReviewPolicy: "required",
		},
		Routing: protocol.RuntimeRouting{
			DetectionKey: request.DetectionKey, AdapterKey: adapterKey, ProfileKey: config.Profiles[0],
			ConfigurationFingerprint: fingerprint, EffectiveModel: model,
			SelectionReason: "primary", SelectionDetail: "Explicit owner or administrator runtime connectivity test.",
			ExecutionMode: executionMode, IsolationPolicy: isolationPolicy,
			DataClasses: []string{}, MaxInputUnits: min(config.MaxInputUnits, 512), MaxOutputUnits: min(config.MaxOutputUnits, 32),
		},
	}
}

func isRuntimeTestAdmission(request protocol.AdmissionRequest) bool {
	return request.Task.Title == "Verify configured provider runtime" &&
		request.Task.InputContext == "This fixed connectivity check contains no customer or workspace data." &&
		request.Task.ExpectedOutput == runtimeTestSentinel &&
		request.Agent.Instructions == "Return exactly the expected sentinel. Do not use tools, files, memory, web access, or other context." &&
		len(request.Agent.AllowedTools) == 0 && len(request.Routing.DataClasses) == 0 &&
		request.Agent.MaxSteps == 1 && request.Agent.MaxToolCalls == 0
}

func evaluateRuntimeTest(events []protocol.CanonicalEvent, executeErr error, executionMode, model, fingerprint string, testedAt time.Time) runtimecatalog.TestResult {
	result := runtimecatalog.TestResult{
		Status: "failed", FailureCode: "runtime_test_failed", EffectiveModel: model, ExecutionMode: executionMode,
		ConfigurationFingerprint: fingerprint, TestedAt: testedAt.UTC(),
	}
	output, completed, prohibitedTool, terminalFailure := "", false, false, false
	for _, event := range events {
		switch event.EventType {
		case "tool.completed":
			prohibitedTool = true
		case "output.produced":
			value, _ := event.Data["text"].(string)
			if output == "" {
				output = value
			} else {
				output = "multiple_outputs"
			}
		case "usage.observed":
			result.UsageObserved = true
			result.InputUnits, _ = event.Data["input_units"].(int)
			result.OutputUnits, _ = event.Data["output_units"].(int)
		case "run.completed":
			if !terminalFailure {
				completed = true
			}
		case "run.timed_out":
			if !terminalFailure {
				result.FailureCode, terminalFailure = "runtime_test_timed_out", true
			}
		case "run.canceled":
			if !terminalFailure {
				result.FailureCode, terminalFailure = "runtime_test_canceled", true
			}
		case "run.failed":
			if !terminalFailure {
				if code, ok := event.Data["code"].(string); ok && len(code) <= 64 {
					result.FailureCode = code
				}
				terminalFailure = true
			}
		}
	}
	if prohibitedTool {
		result.FailureCode = "prohibited_tool_use"
		return result
	}
	if executeErr != nil {
		return result
	}
	if terminalFailure {
		return result
	}
	if !completed || output != runtimeTestSentinel {
		result.FailureCode = "unexpected_sentinel"
		return result
	}
	result.Status, result.FailureCode = "passed", ""
	return result
}

func min(left, right int) int {
	if left < right {
		return left
	}
	return right
}

func (registry *Registry) executeScripted(ctx context.Context, request protocol.AdmissionRequest, emit func(protocol.CanonicalEvent) error) error {
	config, ok := registry.config.Adapters["scripted"]
	path := registry.config.Scripted[request.Routing.ProfileKey]
	_, detectionKey, fingerprint, script, fingerprintErr := scriptedRuntimeIdentity(registry.config, registry.configurationIdentityKey, path)
	if !boundedExecutionBoundary(request) || !ok || !config.Enabled || !config.allows(request) || path == "" ||
		fingerprintErr != nil || detectionKey != request.Routing.DetectionKey ||
		request.Routing.ConfigurationFingerprint != fingerprint || request.Routing.EffectiveModel != "deterministic_fixture" {
		return ErrPolicyDenied
	}
	_, err := scripted.New(registry.now).Execute(ctx, request, script, emit)
	return err
}

func executionPrompt(request protocol.AdmissionRequest) (string, error) {
	payload := map[string]any{
		"instructions": request.Agent.Instructions,
		"task": map[string]string{
			"title": request.Task.Title, "input_context": request.Task.InputContext,
			"expected_output": request.Task.ExpectedOutput,
		},
		"allowed_tools":      request.Agent.AllowedTools,
		"maximum_steps":      request.Agent.MaxSteps,
		"maximum_tool_calls": request.Agent.MaxToolCalls,
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	return "Complete this NavishAI task using only the supplied context and policy. Return the requested structured output.\n" + string(encoded), nil
}

func (config AdapterConfig) allows(request protocol.AdmissionRequest) bool {
	return contains(config.Profiles, request.Routing.ProfileKey) && contains(config.Roles, request.Agent.RoleKey) &&
		subset(request.Agent.AllowedTools, config.Tools) && subset(request.Routing.DataClasses, config.DataClasses) &&
		request.Agent.TimeoutSeconds <= config.MaxTimeoutSeconds && request.Agent.MaxSteps <= config.MaxSteps &&
		request.Agent.MaxToolCalls <= config.MaxToolCalls && request.Routing.MaxInputUnits <= config.MaxInputUnits &&
		request.Routing.MaxOutputUnits <= config.MaxOutputUnits
}

func anyManagedAdapterTemplate(config Config) bool {
	for key, adapter := range config.Adapters {
		if managedAdapterTemplateValid(config, key, adapter) {
			return true
		}
	}
	return false
}

func anyLegacyLiveAdapter(configs map[string]AdapterConfig) bool {
	for key, adapter := range configs {
		if key != "scripted" && adapter.Enabled {
			return true
		}
	}
	return false
}

func ScriptedDetectionKey(path string) string {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return ""
	}
	body, err := scripted.ReadFixture(resolved)
	if err != nil {
		return ""
	}
	return scriptedDetectionKeyFromBytes(resolved, body)
}

func scriptedDetectionKeyFromBytes(resolved string, body []byte) string {
	digest := sha256.New()
	_, _ = digest.Write([]byte("scripted\x00" + resolved + "\x00"))
	_, _ = digest.Write(body)
	return hex.EncodeToString(digest.Sum(nil))
}

func ScriptedInstallations(config Config, configurationIdentityKey []byte, checkedAt time.Time) ([]runtimecatalog.Installation, error) {
	adapter, ok := config.Adapters["scripted"]
	if !ok || !adapter.Enabled {
		return nil, nil
	}
	if err := protocol.ValidateSecret(configurationIdentityKey); err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	installations := []runtimecatalog.Installation{}
	for _, path := range config.Scripted {
		resolved, key, fingerprint, _, err := scriptedRuntimeIdentity(config, configurationIdentityKey, path)
		if err != nil || key == "" || seen[key] {
			continue
		}
		seen[key] = true
		installations = append(installations, runtimecatalog.Installation{
			DetectionKey: key, AdapterKey: "scripted", ProtocolVersion: protocol.Version,
			ExecutablePath: resolved, ExecutableVersion: "scripted 1.0.0",
			AccountMetadata: map[string]string{"authentication": "built_in"},
			Transport:       runtimecatalog.TransportBuiltInHTTPS, ExecutionMode: protocol.ExecutionModeBounded,
			Capabilities:   []string{runtimecatalog.RuntimeTestCapability, "structured_output", "tool_calling"},
			EffectiveModel: "deterministic_fixture", ConfigurationFingerprint: fingerprint,
			MinimumVersion: "1.0.0", MaximumVersion: "1.0.0", CompatibilityStatus: "compatible",
			HealthStatus: "available", CheckedAt: checkedAt.UTC().Format(time.RFC3339Nano),
		})
	}
	return installations, nil
}

func ScriptedConfigurationFingerprint(config Config, configurationIdentityKey []byte) (string, error) {
	path := config.Scripted["workspace_default"]
	if path == "" {
		profiles := make([]string, 0, len(config.Scripted))
		for profile := range config.Scripted {
			profiles = append(profiles, profile)
		}
		sort.Strings(profiles)
		if len(profiles) > 0 {
			path = config.Scripted[profiles[0]]
		}
	}
	_, _, fingerprint, _, err := scriptedRuntimeIdentity(config, configurationIdentityKey, path)
	return fingerprint, err
}

func scriptedRuntimeIdentity(config Config, configurationIdentityKey []byte, path string) (string, string, string, scripted.Script, error) {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", "", "", scripted.Script{}, err
	}
	body, err := scripted.ReadFixture(resolved)
	if err != nil {
		return "", "", "", scripted.Script{}, err
	}
	detectionKey := scriptedDetectionKeyFromBytes(resolved, body)
	if detectionKey == "" {
		return "", "", "", scripted.Script{}, errors.New("scripted fixture detection failed")
	}
	fixture, err := scripted.Decode(bytes.NewReader(body))
	if err != nil {
		return "", "", "", scripted.Script{}, err
	}
	adapter := config.Adapters["scripted"]
	adapter.Model = "deterministic_fixture"
	_, fingerprint, err := AdapterConfigurationIdentityForRuntime(
		"scripted", adapter, config.Supervisor, "", "", configurationIdentityKey,
		resolved, detectionKey, "scripted 1.0.0", protocol.ExecutionModeBounded,
	)
	return resolved, detectionKey, fingerprint, fixture, err
}

func contains(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}

func supportsRuntimeTest(installation runtimecatalog.Installation) bool {
	return contains(installation.Capabilities, runtimecatalog.RuntimeTestCapability)
}

func subset(values, allowed []string) bool {
	for _, value := range values {
		if !contains(allowed, value) {
			return false
		}
	}
	return true
}
