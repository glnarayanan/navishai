package execution

import (
	"context"
	"net/http"
	"sort"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters/claude"
	"github.com/glnarayanan/navishai/runner/internal/adapters/codex"
	"github.com/glnarayanan/navishai/runner/internal/adapters/cursor"
	"github.com/glnarayanan/navishai/runner/internal/adapters/grok"
	"github.com/glnarayanan/navishai/runner/internal/providerconfig"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

type ManagedCatalog struct {
	config      Config
	providers   *providerconfig.Store
	identityKey []byte
	now         func() time.Time
	scripted    []runtimecatalog.Installation
	supported   func() bool
}

func NewManagedCatalog(config Config, providers *providerconfig.Store, identityKey []byte, now func() time.Time) (*ManagedCatalog, error) {
	if providers == nil {
		return nil, ErrPolicyDenied
	}
	if now == nil {
		now = time.Now
	}
	scripted, err := ScriptedInstallations(config, identityKey, now())
	if err != nil {
		return nil, err
	}
	return &ManagedCatalog{config: config, providers: providers, identityKey: append([]byte(nil), identityKey...), now: now, scripted: scripted, supported: supervisor.Supported}, nil
}

func (catalog *ManagedCatalog) DetectWorkspace(ctx context.Context, workspaceKey string) []runtimecatalog.Installation {
	installations := catalog.apiKeyInstallations(workspaceKey)
	workspaceCatalog, err := catalog.workspaceCatalog(workspaceKey, true)
	if err == nil {
		installations = append(installations, catalog.approvedDetections(ctx, workspaceCatalog)...)
	}
	sort.Slice(installations, func(left, right int) bool {
		if installations[left].AdapterKey == installations[right].AdapterKey {
			return installations[left].DetectionKey < installations[right].DetectionKey
		}
		return installations[left].AdapterKey < installations[right].AdapterKey
	})
	return installations
}

func (catalog *ManagedCatalog) ResolveApprovedWorkspace(ctx context.Context, workspaceKey, wantedKey string, approvedPaths []string) (runtimecatalog.Installation, bool) {
	for _, installation := range catalog.apiKeyInstallations(workspaceKey) {
		if installation.DetectionKey == wantedKey {
			return installation, true
		}
	}
	workspaceCatalog, err := catalog.workspaceCatalog(workspaceKey, true)
	if err != nil {
		return runtimecatalog.Installation{}, false
	}
	return workspaceCatalog.ResolveApproved(ctx, wantedKey, approvedPaths)
}

func (catalog *ManagedCatalog) ProviderAvailability(request *http.Request, workspaceKey, adapterKey string) providerconfig.Availability {
	if catalog != nil && catalog.providers != nil {
		if connection, configured := catalog.providers.Get(workspaceKey, adapterKey); configured && connection.AuthMode == "api_key" && isDirectProviderAPIAdapter(adapterKey) {
			adapter, ok := catalog.config.Adapters[adapterKey]
			installation, available := providerAPIInstallation(workspaceKey, adapterKey, adapter, connection, catalog.identityKey, catalog.now())
			if !ok || !available {
				return providerconfig.Availability{HealthStatus: "unavailable"}
			}
			return providerconfig.Availability{HealthStatus: installation.HealthStatus, Available: true, ExecutableVersion: installation.ExecutableVersion}
		}
	}
	if catalog == nil || catalog.supported == nil || !catalog.supported() {
		return providerconfig.Availability{HealthStatus: "unavailable"}
	}
	definition, ok := catalog.definition(adapterKey, workspaceKey, false)
	if !ok {
		return providerconfig.Availability{HealthStatus: "unavailable"}
	}
	probeCatalog, err := runtimecatalog.New([]runtimecatalog.Definition{definition}, catalog.now)
	if err != nil {
		return providerconfig.Availability{HealthStatus: "unavailable"}
	}
	installations := catalog.approvedDetections(request.Context(), probeCatalog)
	if len(installations) != 1 {
		return providerconfig.Availability{HealthStatus: "unavailable"}
	}
	installation := installations[0]
	available := installation.HealthStatus == "available" && installation.CompatibilityStatus == "compatible"
	return providerconfig.Availability{
		HealthStatus: installation.HealthStatus, Available: available, ExecutableVersion: installation.ExecutableVersion,
	}
}

func (catalog *ManagedCatalog) apiKeyInstallations(workspaceKey string) []runtimecatalog.Installation {
	if catalog == nil || catalog.providers == nil {
		return nil
	}
	installations := make([]runtimecatalog.Installation, 0, 2)
	for _, adapterKey := range []string{codex.AdapterKey, claude.AdapterKey} {
		connection, configured := catalog.providers.Get(workspaceKey, adapterKey)
		if !configured {
			continue
		}
		adapter, ok := catalog.config.Adapters[adapterKey]
		if installation, available := providerAPIInstallation(workspaceKey, adapterKey, adapter, connection, catalog.identityKey, catalog.now()); available {
			installations = append(installations, installation)
		}
	}
	return installations
}

func (catalog *ManagedCatalog) approvedDetections(ctx context.Context, workspaceCatalog *runtimecatalog.Catalog) []runtimecatalog.Installation {
	return workspaceCatalog.DetectApproved(ctx, catalog.config.Supervisor.ApprovedExecutables)
}

func (catalog *ManagedCatalog) workspaceCatalog(workspaceKey string, configuredOnly bool) (*runtimecatalog.Catalog, error) {
	definitions := make([]runtimecatalog.Definition, 0, 4)
	if catalog.supported == nil || !catalog.supported() {
		return runtimecatalog.NewWithInstallations(definitions, catalog.scripted, catalog.now)
	}
	for _, provider := range providerconfig.Definitions() {
		definition, ok := catalog.definition(provider.AdapterKey, workspaceKey, configuredOnly)
		if ok {
			definitions = append(definitions, definition)
		}
	}
	return runtimecatalog.NewWithInstallations(definitions, catalog.scripted, catalog.now)
}

func (catalog *ManagedCatalog) definition(adapterKey, workspaceKey string, configuredOnly bool) (runtimecatalog.Definition, bool) {
	adapterConfig, allowed := catalog.config.Adapters[adapterKey]
	if !allowed || !managedAdapterTemplateValid(catalog.config, adapterKey, adapterConfig) {
		return runtimecatalog.Definition{}, false
	}
	connection, configured := catalog.providers.Get(workspaceKey, adapterKey)
	if configuredOnly && !configured {
		return runtimecatalog.Definition{}, false
	}
	if configured && connection.AuthMode == "api_key" && isDirectProviderAPIAdapter(adapterKey) {
		return runtimecatalog.Definition{}, false
	}
	definition, ok := baseDefinition(adapterKey)
	if !ok {
		return runtimecatalog.Definition{}, false
	}
	authMode, apiKey := "subscription", ""
	if configured {
		authMode, apiKey = connection.AuthMode, connection.APIKey
		adapterConfig.Model = connection.Model
	}
	model, fingerprint, err := adapterConfigurationIdentityFor(adapterKey, adapterConfig, catalog.config.Supervisor, authMode, apiKey, catalog.identityKey)
	if err != nil {
		return runtimecatalog.Definition{}, false
	}
	definition.EffectiveModel, definition.ConfigurationFingerprint = model, fingerprint
	definition.ConfigurationIdentity = func(executablePath, detectionKey, observedVersion string) (string, string, error) {
		return AdapterConfigurationIdentityForRuntime(
			adapterKey, adapterConfig, catalog.config.Supervisor, authMode, apiKey, catalog.identityKey,
			executablePath, detectionKey, observedVersion,
		)
	}
	definition.AccountHome = adapterConfig.HomeDir
	definition.AccountEnvironmentValues = make(map[string]string)
	if !configured || authMode == "api_key" {
		definition.AccountArguments = nil
		definition.AccountMarker = ""
		definition.AccountValidator = nil
		definition.AccountEnvironment = nil
		authentication := "not_configured"
		if configured {
			authentication = "api_key"
		}
		definition.AccountMetadata = map[string]string{"authentication": authentication}
	} else {
		switch adapterKey {
		case codex.AdapterKey:
			definition.AccountEnvironment = nil
			definition.AccountEnvironmentValues["CODEX_HOME"] = adapterConfig.HomeDir
		case claude.AdapterKey:
			definition.AccountEnvironment = nil
			definition.AccountEnvironmentValues["CLAUDE_CONFIG_DIR"] = adapterConfig.HomeDir
		}
	}
	return definition, true
}

func managedAdapterTemplateValid(config Config, adapterKey string, adapter AdapterConfig) bool {
	if adapterKey == "scripted" || adapter.HomeDir == "" || adapter.EgressProfileKey == "" ||
		len(adapter.Profiles) == 0 || len(adapter.Roles) == 0 || len(adapter.DataClasses) == 0 {
		return false
	}
	for _, profile := range config.Supervisor.EgressProfiles {
		if profile.Key == adapter.EgressProfileKey {
			return true
		}
	}
	return false
}

func baseDefinition(adapterKey string) (runtimecatalog.Definition, bool) {
	switch adapterKey {
	case codex.AdapterKey:
		return codex.Definition(), true
	case claude.AdapterKey:
		return claude.Definition(), true
	case grok.AdapterKey:
		return grok.Definition(), true
	case cursor.AdapterKey:
		return cursor.Definition(), true
	default:
		return runtimecatalog.Definition{}, false
	}
}
