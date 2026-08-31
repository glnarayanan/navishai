package execution

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters/claude"
	"github.com/glnarayanan/navishai/runner/internal/adapters/codex"
	"github.com/glnarayanan/navishai/runner/internal/adapters/cursor"
	"github.com/glnarayanan/navishai/runner/internal/adapters/grok"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
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
	supervisor               *supervisor.Supervisor
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
		supervisor:               processSupervisor, now: now,
	}
	registry.execute = registry.Execute
	return registry, nil
}

func (registry *Registry) Execute(ctx context.Context, request protocol.AdmissionRequest, emit func(protocol.CanonicalEvent) error) error {
	if request.Validate() != nil || emit == nil {
		return ErrPolicyDenied
	}
	if request.Routing.AdapterKey == "scripted" {
		return registry.executeScripted(ctx, request, emit)
	}
	adapterConfig, credentials, ok := registry.effectiveAdapter(request.WorkspaceKey, request.Routing.AdapterKey)
	if !ok || !adapterConfig.allows(request) || registry.supervisor == nil ||
		adapterConfig.HomeDir == "" || adapterConfig.EgressProfileKey == "" {
		return ErrPolicyDenied
	}
	installation, ok := registry.catalog.ResolveApprovedWorkspace(
		ctx, request.WorkspaceKey, request.Routing.DetectionKey, registry.config.Supervisor.ApprovedExecutables,
	)
	if !ok || installation.AdapterKey != request.Routing.AdapterKey || installation.HealthStatus != "available" ||
		installation.CompatibilityStatus != "compatible" || installation.ConfigurationFingerprint != request.Routing.ConfigurationFingerprint ||
		installation.EffectiveModel != request.Routing.EffectiveModel {
		return ErrPolicyDenied
	}
	workingDir, err := registry.workingDirectory(request.RunID)
	if err != nil {
		return err
	}
	credentialHome := adapterConfig.HomeDir
	if len(credentials) > 0 {
		credentialHome = workingDir
	}
	prompt, err := executionPrompt(request)
	if err != nil {
		return err
	}
	runContext, cancel := context.WithTimeout(ctx, time.Duration(request.Agent.TimeoutSeconds)*time.Second)
	defer cancel()

	switch request.Routing.AdapterKey {
	case codex.AdapterKey:
		_, err = codex.New(registry.now).Execute(runContext, codex.Invocation{
			Admission: request, Executable: installation.ExecutablePath, WorkingDir: workingDir,
			CodexHome: credentialHome, Model: adapterConfig.Model, Prompt: prompt,
			DisableTools: isRuntimeTestAdmission(request), Credentials: credentials, EgressProfileKey: adapterConfig.EgressProfileKey,
		}, registry.supervisor, emit)
	case claude.AdapterKey:
		_, err = claude.New(registry.now).Execute(runContext, claude.Invocation{
			Admission: request, Executable: installation.ExecutablePath, WorkingDir: workingDir,
			ClaudeConfigDir: credentialHome, Model: adapterConfig.Model, Prompt: prompt,
			Credentials: credentials, EgressProfileKey: adapterConfig.EgressProfileKey,
		}, registry.supervisor, emit)
	case grok.AdapterKey:
		_, err = grok.New(registry.now).Execute(runContext, grok.Invocation{
			Admission: request, Executable: installation.ExecutablePath, WorkingDir: workingDir,
			GrokHome: credentialHome, Model: adapterConfig.Model, Prompt: prompt,
			Credentials: credentials, EgressProfileKey: adapterConfig.EgressProfileKey,
		}, registry.supervisor, emit)
	case cursor.AdapterKey:
		_, err = cursor.New(registry.now).Execute(runContext, cursor.Invocation{
			Admission: request, Executable: installation.ExecutablePath, WorkingDir: workingDir,
			CursorHome: adapterConfig.HomeDir, Prompt: prompt, EgressProfileKey: adapterConfig.EgressProfileKey,
		}, registry.supervisor, emit)
	default:
		return ErrPolicyDenied
	}
	return err
}

func (registry *Registry) TestRuntime(ctx context.Context, request runtimecatalog.TestRequest) (runtimecatalog.TestResult, error) {
	installation, ok := registry.catalog.ResolveApprovedWorkspace(ctx, request.WorkspaceKey, request.DetectionKey, registry.config.Supervisor.ApprovedExecutables)
	if !ok || !supportsRuntimeTest(installation) ||
		installation.ConfigurationFingerprint != request.ConfigurationFingerprint {
		return runtimecatalog.TestResult{}, runtimecatalog.ErrTestConfigurationChanged
	}
	var adapterConfig AdapterConfig
	if installation.AdapterKey == "scripted" {
		adapterConfig, ok = registry.config.Adapters[installation.AdapterKey]
		ok = ok && adapterConfig.Enabled
	} else {
		adapterConfig, _, ok = registry.effectiveAdapter(request.WorkspaceKey, installation.AdapterKey)
	}
	if !ok || len(adapterConfig.Profiles) == 0 || len(adapterConfig.Roles) == 0 {
		return runtimecatalog.TestResult{}, runtimecatalog.ErrTestConfigurationChanged
	}
	authMode, apiKey := "", ""
	if registry.providers != nil && installation.AdapterKey != "scripted" {
		connection, configured := registry.providers.Get(request.WorkspaceKey, installation.AdapterKey)
		if !configured {
			return runtimecatalog.TestResult{}, runtimecatalog.ErrTestConfigurationChanged
		}
		authMode, apiKey = connection.AuthMode, connection.APIKey
	}
	model, fingerprint, err := registry.runtimeTestConfiguration(installation.AdapterKey, adapterConfig, authMode, apiKey)
	if err != nil || model != installation.EffectiveModel || fingerprint != request.ConfigurationFingerprint {
		return runtimecatalog.TestResult{}, runtimecatalog.ErrTestConfigurationChanged
	}
	admission := runtimeTestAdmission(request, installation.AdapterKey, adapterConfig, model, fingerprint)
	if admission.Validate() != nil {
		return runtimecatalog.TestResult{}, ErrPolicyDenied
	}
	testWorkingDirectory := filepath.Join(registry.config.WorkRoot, admission.RunID)
	if _, err := os.Lstat(testWorkingDirectory); !errors.Is(err, os.ErrNotExist) {
		return runtimecatalog.TestResult{}, ErrPolicyDenied
	}
	defer os.RemoveAll(testWorkingDirectory)
	events := []protocol.CanonicalEvent{}
	executeErr := registry.execute(ctx, admission, func(event protocol.CanonicalEvent) error {
		events = append(events, event)
		return nil
	})
	return evaluateRuntimeTest(events, executeErr, model, fingerprint, registry.now()), nil
}

func (registry *Registry) runtimeTestConfiguration(adapterKey string, adapterConfig AdapterConfig, authMode, apiKey string) (string, string, error) {
	if adapterKey == "scripted" {
		fingerprint, err := ScriptedConfigurationFingerprint(registry.config, registry.configurationIdentityKey)
		return "deterministic_fixture", fingerprint, err
	}
	return adapterConfigurationIdentityFor(
		adapterKey, adapterConfig, registry.config.Supervisor, authMode, apiKey, registry.configurationIdentityKey,
	)
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

func runtimeTestAdmission(request runtimecatalog.TestRequest, adapterKey string, config AdapterConfig, model, fingerprint string) protocol.AdmissionRequest {
	timeout := min(config.MaxTimeoutSeconds, 30)
	return protocol.AdmissionRequest{
		ProtocolVersion: protocol.Version,
		RunID:           request.RequestID,
		IdempotencyKey:  "runtime-test-" + request.RequestID,
		WorkspaceKey:    request.WorkspaceKey,
		Task: protocol.Task{
			TaskKey: request.RequestID, Attempt: 1, Title: "Verify configured subscription runtime",
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
			DataClasses: []string{}, MaxInputUnits: min(config.MaxInputUnits, 512), MaxOutputUnits: min(config.MaxOutputUnits, 32),
		},
	}
}

func isRuntimeTestAdmission(request protocol.AdmissionRequest) bool {
	return request.Task.Title == "Verify configured subscription runtime" &&
		request.Task.InputContext == "This fixed connectivity check contains no customer or workspace data." &&
		request.Task.ExpectedOutput == runtimeTestSentinel &&
		request.Agent.Instructions == "Return exactly the expected sentinel. Do not use tools, files, memory, web access, or other context." &&
		len(request.Agent.AllowedTools) == 0 && len(request.Routing.DataClasses) == 0 &&
		request.Agent.MaxSteps == 1 && request.Agent.MaxToolCalls == 0
}

func evaluateRuntimeTest(events []protocol.CanonicalEvent, executeErr error, model, fingerprint string, testedAt time.Time) runtimecatalog.TestResult {
	result := runtimecatalog.TestResult{
		Status: "failed", FailureCode: "runtime_test_failed", EffectiveModel: model,
		ConfigurationFingerprint: fingerprint, TestedAt: testedAt.UTC(),
	}
	output, completed, prohibitedTool := "", false, false
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
			completed = true
		case "run.timed_out":
			result.FailureCode = "runtime_test_timed_out"
		case "run.canceled":
			result.FailureCode = "runtime_test_canceled"
		case "run.failed":
			if code, ok := event.Data["code"].(string); ok && len(code) <= 64 {
				result.FailureCode = code
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
	fingerprint, fingerprintErr := ScriptedConfigurationFingerprint(registry.config, registry.configurationIdentityKey)
	if !ok || !config.Enabled || !config.allows(request) || path == "" ||
		fingerprintErr != nil || ScriptedDetectionKey(path) != request.Routing.DetectionKey ||
		request.Routing.ConfigurationFingerprint != fingerprint || request.Routing.EffectiveModel != "deterministic_fixture" {
		return ErrPolicyDenied
	}
	script, err := scripted.Load(path)
	if err != nil {
		return err
	}
	_, err = scripted.New(registry.now).Execute(ctx, request, script, emit)
	return err
}

func (registry *Registry) workingDirectory(runID string) (string, error) {
	path := filepath.Join(registry.config.WorkRoot, runID)
	if err := os.Mkdir(path, 0o700); err != nil {
		return "", err
	}
	return path, nil
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
	file, err := os.Open(resolved)
	if err != nil {
		return ""
	}
	defer file.Close()
	digest := sha256.New()
	_, _ = digest.Write([]byte("scripted\x00" + resolved + "\x00"))
	if _, err := file.WriteTo(digest); err != nil {
		return ""
	}
	return hex.EncodeToString(digest.Sum(nil))
}

func ScriptedInstallations(config Config, configurationIdentityKey []byte, checkedAt time.Time) ([]runtimecatalog.Installation, error) {
	adapter, ok := config.Adapters["scripted"]
	if !ok || !adapter.Enabled {
		return nil, nil
	}
	fingerprint, err := ScriptedConfigurationFingerprint(config, configurationIdentityKey)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	installations := []runtimecatalog.Installation{}
	for _, path := range config.Scripted {
		resolved, err := filepath.EvalSymlinks(path)
		key := ScriptedDetectionKey(path)
		if err != nil || key == "" || seen[key] {
			continue
		}
		seen[key] = true
		installations = append(installations, runtimecatalog.Installation{
			DetectionKey: key, AdapterKey: "scripted", ProtocolVersion: protocol.Version,
			ExecutablePath: resolved, ExecutableVersion: "scripted 1.0.0",
			AccountMetadata: map[string]string{"authentication": "built_in"},
			Capabilities:    []string{runtimecatalog.RuntimeTestCapability, "structured_output", "tool_calling"},
			EffectiveModel:  "deterministic_fixture", ConfigurationFingerprint: fingerprint,
			MinimumVersion: "1.0.0", MaximumVersion: "1.0.0", CompatibilityStatus: "compatible",
			HealthStatus: "available", CheckedAt: checkedAt.UTC().Format(time.RFC3339Nano),
		})
	}
	return installations, nil
}

func ScriptedConfigurationFingerprint(config Config, configurationIdentityKey []byte) (string, error) {
	_, fingerprint, err := AdapterConfigurationIdentity(
		"scripted", config.Adapters["scripted"], config.Supervisor, configurationIdentityKey,
	)
	return fingerprint, err
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
