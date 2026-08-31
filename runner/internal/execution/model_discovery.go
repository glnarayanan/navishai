package execution

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters"
	"github.com/glnarayanan/navishai/runner/internal/adapters/codex"
	"github.com/glnarayanan/navishai/runner/internal/adapters/cursor"
	"github.com/glnarayanan/navishai/runner/internal/providerconfig"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

const modelDiscoveryTimeout = 15 * time.Second

func (registry *Registry) DiscoverModels(request *http.Request, workspaceKey, adapterKey string) providerconfig.ModelDiscovery {
	spec, ok := modelDiscoverySpec(adapterKey)
	if !ok {
		return providerconfig.ModelDiscovery{Status: providerconfig.ModelDiscoveryUnsupported}
	}
	if registry == nil || request == nil || registry.providers == nil || registry.processRunner == nil || registry.config.WorkRoot == "" {
		return failedModelDiscovery()
	}
	adapterConfig, credentials, ok := registry.effectiveAdapter(workspaceKey, adapterKey)
	if !ok {
		return failedModelDiscovery()
	}
	ctx, cancel := context.WithTimeout(request.Context(), modelDiscoveryTimeout)
	defer cancel()
	executable, ok := registry.approvedModelDiscoveryExecutable(adapterKey)
	if !ok {
		return failedModelDiscovery()
	}
	workingDirectory, err := os.MkdirTemp(registry.config.WorkRoot, ".model-discovery-*")
	if err != nil {
		return failedModelDiscovery()
	}
	credentialHome := adapterConfig.HomeDir
	if len(credentials) > 0 {
		credentialHome = workingDirectory
	}
	if adapterKey == codex.AdapterKey {
		if credentials == nil {
			credentials = make(map[string]string)
		}
		credentials["CODEX_HOME"] = credentialHome
	}
	defer os.RemoveAll(workingDirectory)
	process, err := registry.processRunner.Run(ctx, supervisor.Request{
		Executable: executable, Arguments: append([]string(nil), spec.Arguments...),
		WorkingDir: workingDirectory, HomeDir: credentialHome, Credentials: credentials,
		EgressProfileKey: adapterConfig.EgressProfileKey,
	})
	if err != nil || process.TimedOut || process.Canceled || process.OutputExceeded || process.ExitCode != 0 || ctx.Err() != nil {
		return failedModelDiscovery()
	}
	if len(process.StandardOutput) == 0 || len(process.StandardOutput) > adapters.MaxModelDiscoveryOutputBytes {
		return failedModelDiscovery()
	}
	models, err := spec.Parse([]byte(process.StandardOutput))
	if err != nil || adapters.ValidateModelOptions(models) != nil {
		return failedModelDiscovery()
	}
	options := make([]providerconfig.ModelOption, 0, len(models))
	for _, model := range models {
		options = append(options, providerconfig.ModelOption{ID: model.ID, Label: model.Label, Default: model.Default})
	}
	return providerconfig.ModelDiscovery{Status: providerconfig.ModelDiscoveryAvailable, Models: options}
}

func modelDiscoverySpec(adapterKey string) (adapters.ModelDiscoverySpec, bool) {
	switch adapterKey {
	case codex.AdapterKey:
		return codex.ModelDiscovery(), true
	case cursor.AdapterKey:
		return cursor.ModelDiscovery(), true
	default:
		return adapters.ModelDiscoverySpec{}, false
	}
}

func (registry *Registry) approvedModelDiscoveryExecutable(adapterKey string) (string, bool) {
	var names []string
	switch adapterKey {
	case codex.AdapterKey:
		names = codex.Definition().ExecutableNames
	case cursor.AdapterKey:
		names = cursor.Definition().ExecutableNames
	default:
		return "", false
	}
	approved := make(map[string]string, len(registry.config.Supervisor.ApprovedExecutables))
	for _, path := range registry.config.Supervisor.ApprovedExecutables {
		resolved, err := runtimecatalog.ResolveApprovedExecutable(path)
		if err != nil {
			continue
		}
		approved[filepath.Base(resolved)] = resolved
	}
	for _, name := range names {
		if resolved := approved[name]; resolved != "" {
			return resolved, true
		}
	}
	return "", false
}

func failedModelDiscovery() providerconfig.ModelDiscovery {
	return providerconfig.ModelDiscovery{Status: providerconfig.ModelDiscoveryFailed}
}

var _ providerconfig.ModelDiscoverySource = (*Registry)(nil)
