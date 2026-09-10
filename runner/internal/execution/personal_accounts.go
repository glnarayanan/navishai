package execution

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters/codex"
	"github.com/glnarayanan/navishai/runner/internal/personalaccounts"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

func (registry *Registry) PersonalAccountHandler(secret []byte, root string) (http.Handler, error) {
	if registry.personalAccounts != nil || !registry.supported() || !filepath.IsAbs(root) {
		return nil, ErrPolicyDenied
	}
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, err
	}
	resolvedRoot, err := filepath.EvalSymlinks(root)
	if err != nil || resolvedRoot != root {
		return nil, ErrPolicyDenied
	}
	readRoots := append(slices.Clone(registry.config.Supervisor.RuntimeReadRoots), registry.config.Supervisor.AllowedExecutableRoots...)
	for _, readRoot := range readRoots {
		resolved, err := filepath.EvalSymlinks(readRoot)
		if err != nil {
			return nil, ErrPolicyDenied
		}
		relative, err := filepath.Rel(resolved, root)
		if err != nil || (relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))) {
			return nil, ErrPolicyDenied
		}
	}
	config := registry.config.Supervisor.build()
	config.AllowedHomeRoots = append(slices.Clone(config.AllowedHomeRoots), root)
	config.AllowedWorkingRoots = append(slices.Clone(config.AllowedWorkingRoots), root)
	process, err := supervisor.New(config)
	if err != nil {
		return nil, err
	}
	registry.personalRunner = process
	store, err := personalaccounts.OpenStore(root, func(ctx context.Context, home string, challenge func(personalaccounts.Challenge) error) error {
		adapter, executable, ok := registry.personalTemplate()
		if !ok {
			return ErrPolicyDenied
		}
		return (personalaccounts.Codex{Runner: process, Executable: executable, EgressProfileKey: adapter.EgressProfileKey}).Login(ctx, home, challenge)
	}, registry.verifyPersonalAccount)
	if err != nil {
		return nil, err
	}
	registry.personalAccounts = store
	if catalog, ok := registry.catalog.(*ManagedCatalog); ok {
		catalog.personalAccountsEnabled = true
	}
	return personalaccounts.NewHandler(secret, store, registry.personalAccountEnabled)
}

func (registry *Registry) personalTemplate() (AdapterConfig, string, bool) {
	adapter, ok := registry.config.Adapters[codex.AdapterKey]
	if !ok || adapter.EgressProfileKey == "" || len(adapter.Profiles) == 0 || len(adapter.Roles) == 0 {
		return AdapterConfig{}, "", false
	}
	for _, profile := range registry.config.Supervisor.EgressProfiles {
		if profile.Key != adapter.EgressProfileKey || !slices.Contains(registry.config.Supervisor.ApprovedExecutables, profile.Executable) {
			continue
		}
		executable, err := runtimecatalog.ResolveApprovedExecutable(profile.Executable)
		if err != nil {
			return AdapterConfig{}, "", false
		}
		return adapter, executable, true
	}
	return AdapterConfig{}, "", false
}

func (registry *Registry) personalAccountEnabled(workspace string) bool {
	if registry.providers == nil || registry.personalRunner == nil || !registry.supported() {
		return false
	}
	_, _, ok := registry.personalTemplate()
	if !ok {
		return false
	}
	connection, ok := registry.providers.Get(workspace, codex.AdapterKey)
	return ok && connection.AuthMode == "subscription" && connection.ExecutionMode == protocol.ExecutionModeStrongIsolated
}

func (registry *Registry) personalInstallation(ctx context.Context, account personalaccounts.Account, home string) (runtimecatalog.Installation, AdapterConfig, error) {
	if !registry.personalAccountEnabled(account.WorkspaceKey) {
		return runtimecatalog.Installation{}, AdapterConfig{}, ErrPolicyDenied
	}
	adapter, executable, ok := registry.personalTemplate()
	if !ok {
		return runtimecatalog.Installation{}, AdapterConfig{}, ErrPolicyDenied
	}
	connection, _ := registry.providers.Get(account.WorkspaceKey, codex.AdapterKey)
	adapter.HomeDir = home
	adapter.Model = connection.Model
	version, err := registry.personalRunner.Run(ctx, supervisor.Request{Executable: executable, Arguments: []string{"--version"}, WorkingDir: home, HomeDir: home, Credentials: map[string]string{"CODEX_HOME": home}})
	if err != nil || version.ExitCode != 0 || version.TimedOut || version.Canceled || !runtimecatalog.ValidObservedVersion(strings.TrimSpace(version.StandardOutput)) {
		return runtimecatalog.Installation{}, adapter, ErrPolicyDenied
	}
	identity, _ := json.Marshal(struct {
		Owner                  personalaccounts.Owner
		AccountKey, Executable string
	}{account.Owner, account.AccountKey, executable})
	digest := sha256.Sum256(identity)
	detection := hex.EncodeToString(digest[:])
	model, fingerprint, err := AdapterConfigurationIdentityForRuntime(codex.AdapterKey, adapter, registry.config.Supervisor, "subscription", "", registry.configurationIdentityKey, executable, detection, strings.TrimSpace(version.StandardOutput), protocol.ExecutionModeStrongIsolated)
	if err != nil {
		return runtimecatalog.Installation{}, adapter, err
	}
	return runtimecatalog.Installation{DetectionKey: detection, AdapterKey: codex.AdapterKey, ProtocolVersion: protocol.Version, ExecutablePath: executable, ExecutableVersion: strings.TrimSpace(version.StandardOutput), AccountMetadata: map[string]string{"authentication": "personal_chatgpt_subscription"}, Capabilities: []string{"runtime_test", "structured_output", "tool_calling"}, Transport: runtimecatalog.TransportManagedProcess, ExecutionMode: protocol.ExecutionModeStrongIsolated, EffectiveModel: model, ConfigurationFingerprint: fingerprint, CompatibilityStatus: "compatible", HealthStatus: "available", CheckedAt: registry.now().UTC().Format(time.RFC3339Nano)}, adapter, nil
}

func (registry *Registry) verifyPersonalAccount(ctx context.Context, account personalaccounts.Account, home string) (runtimecatalog.Installation, personalaccounts.TestEvidence, error) {
	installation, adapter, err := registry.personalInstallation(ctx, account, home)
	if err != nil {
		return installation, personalaccounts.TestEvidence{}, err
	}
	request := runtimeTestAdmission(runtimecatalog.TestRequest{WorkspaceKey: account.WorkspaceKey, RequestID: account.AccountKey, DetectionKey: installation.DetectionKey}, codex.AdapterKey, adapter, installation.EffectiveModel, installation.ConfigurationFingerprint, protocol.ExecutionModeStrongIsolated, protocol.IsolationPolicyStrongRequired)
	var events []protocol.CanonicalEvent
	err = registry.runPersonalCodex(ctx, request, installation, adapter, home, func(event protocol.CanonicalEvent) error { events = append(events, event); return nil })
	result := evaluateRuntimeTest(events, err, protocol.ExecutionModeStrongIsolated, installation.EffectiveModel, installation.ConfigurationFingerprint, registry.now())
	evidence := personalaccounts.TestEvidence{Status: result.Status, ConfigurationFingerprint: result.ConfigurationFingerprint, ExecutionMode: result.ExecutionMode, EffectiveModel: result.EffectiveModel, TestedAt: result.TestedAt, UsageObserved: result.UsageObserved, InputUnits: result.InputUnits, OutputUnits: result.OutputUnits, FailureCode: result.FailureCode}
	if result.Status != "passed" {
		return installation, evidence, ErrPolicyDenied
	}
	return installation, evidence, nil
}

func (registry *Registry) executePersonalAccount(ctx context.Context, request protocol.AdmissionRequest, emit func(protocol.CanonicalEvent) error) error {
	if registry.personalAccounts == nil || request.Routing.AdapterKey != codex.AdapterKey || request.Routing.ExecutionMode != protocol.ExecutionModeStrongIsolated || !registry.personalAccountEnabled(request.WorkspaceKey) {
		return ErrPolicyDenied
	}
	binding := request.Routing.PersonalAccount
	account, home, release, err := registry.personalAccounts.Acquire(personalaccounts.Owner{WorkspaceKey: request.WorkspaceKey, MembershipID: binding.MembershipID}, binding.AccountKey, request.Routing.ConfigurationFingerprint)
	if err != nil {
		return ErrPolicyDenied
	}
	defer release()
	installation, adapter, err := registry.personalInstallation(ctx, account, home)
	if err != nil || installation.DetectionKey != request.Routing.DetectionKey || installation.ConfigurationFingerprint != request.Routing.ConfigurationFingerprint || installation.EffectiveModel != request.Routing.EffectiveModel || !adapter.allows(request) {
		return ErrPolicyDenied
	}
	return registry.runPersonalCodex(ctx, request, installation, adapter, home, emit)
}

func (registry *Registry) runPersonalCodex(ctx context.Context, request protocol.AdmissionRequest, installation runtimecatalog.Installation, adapter AdapterConfig, home string, emit func(protocol.CanonicalEvent) error) error {
	work, err := createHostWorkingDirectory(registry.config.WorkRoot, request.RunID)
	if err != nil {
		return err
	}
	defer os.RemoveAll(work)
	prompt, err := executionPrompt(request)
	if err != nil {
		return ErrPolicyDenied
	}
	runCtx, cancel := context.WithTimeout(ctx, time.Duration(request.Agent.TimeoutSeconds)*time.Second)
	defer cancel()
	model := adapter.Model
	if model == runtimeDefaultModel {
		model = ""
	}
	_, err = codex.New(registry.now).Execute(runCtx, codex.Invocation{Admission: request, Executable: installation.ExecutablePath, WorkingDir: work, CodexHome: home, Model: model, Prompt: prompt, DisableTools: true, EgressProfileKey: adapter.EgressProfileKey}, personalProcess{registry.personalRunner, home}, emit)
	return err
}

type personalProcess struct {
	runner *supervisor.Supervisor
	home   string
}

func (process personalProcess) Run(ctx context.Context, request supervisor.Request) (supervisor.Result, error) {
	if request.HomeDir != process.home || request.Credentials["CODEX_HOME"] != process.home {
		return supervisor.Result{}, ErrPolicyDenied
	}
	request.WritableHome = true
	return process.runner.Run(ctx, request)
}
