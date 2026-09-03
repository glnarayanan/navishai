package execution

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters"
	"github.com/glnarayanan/navishai/runner/internal/adapters/codex"
	"github.com/glnarayanan/navishai/runner/internal/adapters/cursor"
	"github.com/glnarayanan/navishai/runner/internal/adapters/cursorhost"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/providerconfig"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
)

type cursorHostSource interface {
	Supported() bool
	Execute(context.Context, cursor.Invocation, func(protocol.CanonicalEvent) error) (cursor.Result, error)
	DiscoverModels(context.Context, string, string, string) ([]adapters.ModelOption, error)
}

type codexHostSource interface {
	ExecuteCodex(context.Context, codex.Invocation, func(protocol.CanonicalEvent) error) (codex.Result, error)
	DiscoverCodexModels(context.Context, string, string, string) ([]adapters.ModelOption, error)
}

func isHostTrustedSubscriptionAdapter(adapterKey string) bool {
	return adapterKey == codex.AdapterKey || adapterKey == cursor.AdapterKey
}

func newCursorHostSource(now func() time.Time) cursorHostSource {
	return cursorhost.New(now)
}

func (registry *Registry) executeCursorHost(ctx context.Context, request protocol.AdmissionRequest, connection providerconfig.Connection, emit func(protocol.CanonicalEvent) error) error {
	if registry == nil || registry.providers == nil || registry.catalog == nil || registry.cursorHost == nil ||
		!registry.cursorHost.Supported() || !registry.config.HostTrustedEnabled || emit == nil ||
		request.Routing.AdapterKey != cursor.AdapterKey || request.Routing.ExecutionMode != protocol.ExecutionModeHostTrusted ||
		request.Routing.IsolationPolicy != protocol.IsolationPolicyHostTrustedAllowed || connection.AuthMode != "subscription" ||
		connection.ExecutionMode != protocol.ExecutionModeHostTrusted {
		return ErrPolicyDenied
	}
	adapterConfig, ok := registry.config.Adapters[cursor.AdapterKey]
	if !ok || !managedAdapterTemplateValid(registry.config, cursor.AdapterKey, adapterConfig) || !adapterConfig.allows(request) {
		return ErrPolicyDenied
	}
	if ctx == nil {
		ctx = context.Background()
	}
	installation, ok := registry.catalog.ResolveApprovedWorkspace(
		ctx, request.WorkspaceKey, request.Routing.DetectionKey, registry.config.Supervisor.ApprovedExecutables,
	)
	if !ok || !validCursorHostInstallation(installation) || installation.EffectiveModel != request.Routing.EffectiveModel ||
		installation.ConfigurationFingerprint != request.Routing.ConfigurationFingerprint {
		return ErrPolicyDenied
	}
	adapterConfig.Model = connection.Model
	model, fingerprint, err := AdapterConfigurationIdentityForRuntime(
		cursor.AdapterKey, adapterConfig, registry.config.Supervisor, connection.AuthMode, "", registry.configurationIdentityKey,
		installation.ExecutablePath, installation.DetectionKey, installation.ExecutableVersion, protocol.ExecutionModeHostTrusted,
	)
	if err != nil || model != installation.EffectiveModel || fingerprint != installation.ConfigurationFingerprint ||
		model != request.Routing.EffectiveModel || fingerprint != request.Routing.ConfigurationFingerprint {
		return ErrPolicyDenied
	}
	workingDirectory, err := createHostWorkingDirectory(registry.config.WorkRoot, request.RunID)
	if err != nil {
		return err
	}
	defer os.RemoveAll(workingDirectory)
	prompt, err := executionPrompt(request)
	if err != nil {
		return ErrPolicyDenied
	}
	runContext, cancel := context.WithTimeout(ctx, time.Duration(request.Agent.TimeoutSeconds)*time.Second)
	defer cancel()
	modelArgument := connection.Model
	if modelArgument == runtimeDefaultModel {
		modelArgument = ""
	}
	_, err = registry.cursorHost.Execute(runContext, cursor.Invocation{
		Admission: request, Executable: installation.ExecutablePath, WorkingDir: workingDirectory,
		CursorHome: adapterConfig.HomeDir, Model: modelArgument, Prompt: prompt,
		EgressProfileKey: adapterConfig.EgressProfileKey,
	}, emit)
	return err
}

func (registry *Registry) executeCodexHost(ctx context.Context, request protocol.AdmissionRequest, connection providerconfig.Connection, emit func(protocol.CanonicalEvent) error) error {
	var hostSource codexHostSource
	sourceAvailable := false
	if registry != nil && registry.cursorHost != nil {
		hostSource, sourceAvailable = registry.cursorHost.(codexHostSource)
	}
	if registry == nil || registry.providers == nil || registry.catalog == nil || registry.cursorHost == nil || !sourceAvailable ||
		!registry.cursorHost.Supported() || !registry.config.HostTrustedEnabled || emit == nil ||
		request.Routing.AdapterKey != codex.AdapterKey || request.Routing.ExecutionMode != protocol.ExecutionModeHostTrusted ||
		request.Routing.IsolationPolicy != protocol.IsolationPolicyHostTrustedAllowed || connection.AuthMode != "subscription" ||
		connection.ExecutionMode != protocol.ExecutionModeHostTrusted {
		return ErrPolicyDenied
	}
	adapterConfig, ok := registry.config.Adapters[codex.AdapterKey]
	if !ok || !managedAdapterTemplateValid(registry.config, codex.AdapterKey, adapterConfig) || !adapterConfig.allows(request) {
		return ErrPolicyDenied
	}
	if ctx == nil {
		ctx = context.Background()
	}
	installation, ok := registry.catalog.ResolveApprovedWorkspace(
		ctx, request.WorkspaceKey, request.Routing.DetectionKey, registry.config.Supervisor.ApprovedExecutables,
	)
	if !ok || !validCodexHostInstallation(installation) || installation.EffectiveModel != request.Routing.EffectiveModel ||
		installation.ConfigurationFingerprint != request.Routing.ConfigurationFingerprint {
		return ErrPolicyDenied
	}
	adapterConfig.Model = connection.Model
	model, fingerprint, err := AdapterConfigurationIdentityForRuntime(
		codex.AdapterKey, adapterConfig, registry.config.Supervisor, connection.AuthMode, "", registry.configurationIdentityKey,
		installation.ExecutablePath, installation.DetectionKey, installation.ExecutableVersion, protocol.ExecutionModeHostTrusted,
	)
	if err != nil || model != installation.EffectiveModel || fingerprint != installation.ConfigurationFingerprint ||
		model != request.Routing.EffectiveModel || fingerprint != request.Routing.ConfigurationFingerprint {
		return ErrPolicyDenied
	}
	workingDirectory, err := createHostWorkingDirectory(registry.config.WorkRoot, request.RunID)
	if err != nil {
		return err
	}
	defer os.RemoveAll(workingDirectory)
	prompt, err := executionPrompt(request)
	if err != nil {
		return ErrPolicyDenied
	}
	runContext, cancel := context.WithTimeout(ctx, time.Duration(request.Agent.TimeoutSeconds)*time.Second)
	defer cancel()
	modelArgument := connection.Model
	if modelArgument == runtimeDefaultModel {
		modelArgument = ""
	}
	_, err = hostSource.ExecuteCodex(runContext, codex.Invocation{
		Admission: request, Executable: installation.ExecutablePath, WorkingDir: workingDirectory,
		CodexHome: adapterConfig.HomeDir, Model: modelArgument, Prompt: prompt,
		DisableTools: true, EgressProfileKey: adapterConfig.EgressProfileKey,
	}, emit)
	return err
}

func validCursorHostInstallation(installation runtimecatalog.Installation) bool {
	return installation.AdapterKey == cursor.AdapterKey &&
		installation.Transport == runtimecatalog.TransportManagedProcess &&
		installation.ExecutionMode == protocol.ExecutionModeHostTrusted &&
		installation.HealthStatus == "available" && installation.CompatibilityStatus == "compatible" &&
		slices.Contains(installation.Capabilities, runtimecatalog.RuntimeTestCapability) &&
		slices.Contains(installation.Capabilities, "acp") && slices.Contains(installation.Capabilities, "structured_output")
}

func validCodexHostInstallation(installation runtimecatalog.Installation) bool {
	return installation.AdapterKey == codex.AdapterKey &&
		installation.Transport == runtimecatalog.TransportManagedProcess &&
		installation.ExecutionMode == protocol.ExecutionModeHostTrusted &&
		installation.HealthStatus == "available" && installation.CompatibilityStatus == "compatible" &&
		slices.Contains(installation.Capabilities, runtimecatalog.RuntimeTestCapability) &&
		slices.Contains(installation.Capabilities, "structured_output") && slices.Contains(installation.Capabilities, "tool_calling")
}

func (registry *Registry) discoverCursorHostModels(request *http.Request, workspaceKey string) providerconfig.ModelDiscovery {
	if registry == nil || request == nil || registry.providers == nil || registry.catalog == nil || registry.cursorHost == nil ||
		!registry.cursorHost.Supported() || !registry.config.HostTrustedEnabled {
		return failedModelDiscovery()
	}
	connection, configured := registry.providers.Get(workspaceKey, cursor.AdapterKey)
	if !configured || connection.AuthMode != "subscription" || connection.ExecutionMode != protocol.ExecutionModeHostTrusted {
		return failedModelDiscovery()
	}
	ctx, cancel := context.WithTimeout(request.Context(), modelDiscoveryTimeout)
	defer cancel()
	targetedCatalog, ok := registry.catalog.(runtimecatalog.WorkspaceAdapterCatalog)
	if !ok {
		return failedModelDiscovery()
	}
	installations := targetedCatalog.DetectWorkspaceAdapter(ctx, workspaceKey, cursor.AdapterKey)
	var installation runtimecatalog.Installation
	for _, candidate := range installations {
		if !validCursorHostInstallation(candidate) || !approvedHostExecutable(registry.config.Supervisor.ApprovedExecutables, candidate.ExecutablePath) {
			continue
		}
		if installation.ExecutablePath != "" {
			return failedModelDiscovery()
		}
		installation = candidate
	}
	if installation.ExecutablePath == "" {
		return failedModelDiscovery()
	}
	adapterConfig, ok := registry.config.Adapters[cursor.AdapterKey]
	if !ok || !managedAdapterTemplateValid(registry.config, cursor.AdapterKey, adapterConfig) {
		return failedModelDiscovery()
	}
	adapterConfig.Model = connection.Model
	model, fingerprint, err := AdapterConfigurationIdentityForRuntime(
		cursor.AdapterKey, adapterConfig, registry.config.Supervisor, connection.AuthMode, "", registry.configurationIdentityKey,
		installation.ExecutablePath, installation.DetectionKey, installation.ExecutableVersion, protocol.ExecutionModeHostTrusted,
	)
	if err != nil || model != installation.EffectiveModel || fingerprint != installation.ConfigurationFingerprint {
		return failedModelDiscovery()
	}
	workingDirectory, err := os.MkdirTemp(registry.config.WorkRoot, ".cursor-model-discovery-*")
	if err != nil {
		return failedModelDiscovery()
	}
	defer os.RemoveAll(workingDirectory)
	models, err := registry.cursorHost.DiscoverModels(ctx, installation.ExecutablePath, workingDirectory, adapterConfig.HomeDir)
	if err != nil || adapters.ValidateModelOptions(models) != nil {
		return failedModelDiscovery()
	}
	options := make([]providerconfig.ModelOption, 0, len(models))
	for _, model := range models {
		options = append(options, providerconfig.ModelOption{ID: model.ID, Label: model.Label, Default: model.Default})
	}
	return providerconfig.ModelDiscovery{Status: providerconfig.ModelDiscoveryAvailable, Models: options}
}

func (registry *Registry) discoverCodexHostModels(request *http.Request, workspaceKey string) providerconfig.ModelDiscovery {
	var hostSource codexHostSource
	sourceAvailable := false
	if registry != nil && registry.cursorHost != nil {
		hostSource, sourceAvailable = registry.cursorHost.(codexHostSource)
	}
	if registry == nil || request == nil || registry.providers == nil || registry.catalog == nil || registry.cursorHost == nil || !sourceAvailable ||
		!registry.cursorHost.Supported() || !registry.config.HostTrustedEnabled {
		return failedModelDiscovery()
	}
	connection, configured := registry.providers.Get(workspaceKey, codex.AdapterKey)
	if !configured || connection.AuthMode != "subscription" || connection.ExecutionMode != protocol.ExecutionModeHostTrusted {
		return failedModelDiscovery()
	}
	ctx, cancel := context.WithTimeout(request.Context(), modelDiscoveryTimeout)
	defer cancel()
	targetedCatalog, ok := registry.catalog.(runtimecatalog.WorkspaceAdapterCatalog)
	if !ok {
		return failedModelDiscovery()
	}
	installations := targetedCatalog.DetectWorkspaceAdapter(ctx, workspaceKey, codex.AdapterKey)
	var installation runtimecatalog.Installation
	for _, candidate := range installations {
		if !validCodexHostInstallation(candidate) || !approvedHostExecutable(registry.config.Supervisor.ApprovedExecutables, candidate.ExecutablePath) {
			continue
		}
		if installation.ExecutablePath != "" {
			return failedModelDiscovery()
		}
		installation = candidate
	}
	if installation.ExecutablePath == "" {
		return failedModelDiscovery()
	}
	adapterConfig, ok := registry.config.Adapters[codex.AdapterKey]
	if !ok || !managedAdapterTemplateValid(registry.config, codex.AdapterKey, adapterConfig) {
		return failedModelDiscovery()
	}
	adapterConfig.Model = connection.Model
	model, fingerprint, err := AdapterConfigurationIdentityForRuntime(
		codex.AdapterKey, adapterConfig, registry.config.Supervisor, connection.AuthMode, "", registry.configurationIdentityKey,
		installation.ExecutablePath, installation.DetectionKey, installation.ExecutableVersion, protocol.ExecutionModeHostTrusted,
	)
	if err != nil || model != installation.EffectiveModel || fingerprint != installation.ConfigurationFingerprint {
		return failedModelDiscovery()
	}
	workingDirectory, err := os.MkdirTemp(registry.config.WorkRoot, ".codex-model-discovery-*")
	if err != nil {
		return failedModelDiscovery()
	}
	defer os.RemoveAll(workingDirectory)
	models, err := hostSource.DiscoverCodexModels(ctx, installation.ExecutablePath, workingDirectory, adapterConfig.HomeDir)
	if err != nil || adapters.ValidateModelOptions(models) != nil {
		return failedModelDiscovery()
	}
	options := make([]providerconfig.ModelOption, 0, len(models))
	for _, model := range models {
		options = append(options, providerconfig.ModelOption{ID: model.ID, Label: model.Label, Default: model.Default})
	}
	return providerconfig.ModelDiscovery{Status: providerconfig.ModelDiscoveryAvailable, Models: options}
}

func createHostWorkingDirectory(workRoot, runID string) (string, error) {
	workingDirectory := filepath.Join(workRoot, runID)
	if err := os.Mkdir(workingDirectory, 0o700); err != nil {
		if errors.Is(err, os.ErrExist) {
			return "", ErrPolicyDenied
		}
		return "", err
	}
	return workingDirectory, nil
}

func approvedHostExecutable(approvedPaths []string, executable string) bool {
	for _, path := range approvedPaths {
		resolved, err := runtimecatalog.ResolveApprovedExecutable(path)
		if err == nil && resolved == executable {
			return true
		}
	}
	return false
}
