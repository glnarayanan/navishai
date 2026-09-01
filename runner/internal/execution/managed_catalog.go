package execution

import (
	"context"
	"net/http"
	"sort"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters/claude"
	"github.com/glnarayanan/navishai/runner/internal/adapters/codex"
	"github.com/glnarayanan/navishai/runner/internal/adapters/cursor"
	"github.com/glnarayanan/navishai/runner/internal/adapters/cursorhost"
	"github.com/glnarayanan/navishai/runner/internal/adapters/grok"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/providerconfig"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

type ManagedCatalog struct {
	config               Config
	providers            *providerconfig.Store
	identityKey          []byte
	now                  func() time.Time
	scripted             []runtimecatalog.Installation
	supported            func() bool
	hostTrustedSupported func() bool
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
	hostSource := cursorhost.New(now)
	return &ManagedCatalog{
		config: config, providers: providers, identityKey: append([]byte(nil), identityKey...), now: now,
		scripted: scripted, supported: supervisor.Supported, hostTrustedSupported: hostSource.Supported,
	}, nil
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
	availableModes := catalog.supportedExecutionModes(adapterKey)
	if catalog != nil && catalog.providers != nil {
		connection, configured := catalog.providers.Get(workspaceKey, adapterKey)
		if !configured {
			return providerconfig.Availability{SupportedExecutionModes: availableModes, HealthStatus: "unavailable"}
		}
		if definition, ok := providerconfig.Lookup(adapterKey); ok && definition.RequiresModel(connection.AuthMode) && connection.Model == "" {
			return providerconfig.Availability{
				SupportedExecutionModes: availableModes, HealthStatus: "unavailable",
				UnavailableReason: "Choose a model before testing or running this provider.",
			}
		}
		if connection.AuthMode == "api_key" && isDirectProviderAPIAdapter(adapterKey) {
			if connection.ExecutionMode != protocol.ExecutionModeBounded {
				return providerconfig.Availability{
					SupportedExecutionModes: availableModes,
					HealthStatus:            "unavailable",
					UnavailableReason:       "API-key provider connections require the bounded execution mode.",
				}
			}
			adapter, ok := catalog.config.Adapters[adapterKey]
			installation, available := providerAPIInstallation(workspaceKey, adapterKey, adapter, connection, catalog.identityKey, catalog.now())
			if !ok || !available {
				return providerconfig.Availability{SupportedExecutionModes: availableModes, HealthStatus: "unavailable"}
			}
			return providerconfig.Availability{
				SupportedExecutionModes: availableModes, HealthStatus: installation.HealthStatus,
				Available: true, ExecutableVersion: installation.ExecutableVersion,
			}
		}
		if connection, configured := catalog.providers.Get(workspaceKey, adapterKey); configured {
			switch connection.ExecutionMode {
			case protocol.ExecutionModeLegacyUnknown, "":
				return providerconfig.Availability{
					SupportedExecutionModes: availableModes, HealthStatus: "unavailable",
					UnavailableReason: "Execution mode must be selected again for this provider.",
				}
			case protocol.ExecutionModeHostTrusted:
				if adapterKey != cursor.AdapterKey || !catalog.hostTrustedAvailable() || connection.AuthMode != "subscription" {
					return providerconfig.Availability{
						SupportedExecutionModes: availableModes, HealthStatus: "unavailable",
						UnavailableReason: "Host-trusted execution is available only for an enabled macOS Cursor source.",
					}
				}
				definition, ok := catalog.definition(adapterKey, workspaceKey, true)
				if !ok {
					return providerconfig.Availability{SupportedExecutionModes: availableModes, HealthStatus: "unavailable"}
				}
				probeCatalog, err := runtimecatalog.New([]runtimecatalog.Definition{definition}, catalog.now)
				if err != nil {
					return providerconfig.Availability{SupportedExecutionModes: availableModes, HealthStatus: "unavailable"}
				}
				requestContext := context.Background()
				if request != nil {
					requestContext = request.Context()
				}
				installations := catalog.approvedDetections(requestContext, probeCatalog)
				if len(installations) != 1 {
					return providerconfig.Availability{SupportedExecutionModes: availableModes, HealthStatus: "unavailable"}
				}
				installation := installations[0]
				available := installation.AdapterKey == cursor.AdapterKey &&
					installation.Transport == runtimecatalog.TransportManagedProcess &&
					installation.ExecutionMode == protocol.ExecutionModeHostTrusted &&
					installation.HealthStatus == "available" && installation.CompatibilityStatus == "compatible"
				return providerconfig.Availability{
					SupportedExecutionModes: availableModes, HealthStatus: installation.HealthStatus, Available: available,
					ExecutableVersion: installation.ExecutableVersion,
				}
			case protocol.ExecutionModeStrongIsolated:
				if !catalog.strongIsolationAvailable() {
					return providerconfig.Availability{
						SupportedExecutionModes: availableModes, HealthStatus: "unavailable",
						UnavailableReason: "Strong-isolated provider execution is not supported by this runner deployment.",
					}
				}
				return providerconfig.Availability{
					SupportedExecutionModes: availableModes, HealthStatus: "unavailable",
					UnavailableReason: "Subscription provider execution is not available in this release.",
				}
			}
		}
	}
	if catalog == nil || catalog.providers == nil || catalog.supported == nil || !catalog.supported() {
		return providerconfig.Availability{
			SupportedExecutionModes: availableModes, HealthStatus: "unavailable",
			UnavailableReason: "Strong-isolated provider execution is not supported by this runner deployment.",
		}
	}
	definition, ok := catalog.definition(adapterKey, workspaceKey, false)
	if !ok {
		return providerconfig.Availability{SupportedExecutionModes: availableModes, HealthStatus: "unavailable"}
	}
	probeCatalog, err := runtimecatalog.New([]runtimecatalog.Definition{definition}, catalog.now)
	if err != nil {
		return providerconfig.Availability{SupportedExecutionModes: availableModes, HealthStatus: "unavailable"}
	}
	requestContext := context.Background()
	if request != nil {
		requestContext = request.Context()
	}
	installations := catalog.approvedDetections(requestContext, probeCatalog)
	if len(installations) != 1 {
		return providerconfig.Availability{SupportedExecutionModes: availableModes, HealthStatus: "unavailable"}
	}
	installation := installations[0]
	available := installation.ExecutionMode == protocol.ExecutionModeStrongIsolated &&
		installation.HealthStatus == "available" && installation.CompatibilityStatus == "compatible"
	return providerconfig.Availability{
		SupportedExecutionModes: availableModes, HealthStatus: installation.HealthStatus, Available: available,
		ExecutableVersion: installation.ExecutableVersion,
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
	providerDefinition, ok := providerconfig.Lookup(adapterKey)
	if !ok {
		return runtimecatalog.Definition{}, false
	}
	if configured && providerDefinition.RequiresModel(connection.AuthMode) && connection.Model == "" {
		return runtimecatalog.Definition{}, false
	}
	definition, ok := baseDefinition(adapterKey)
	if !ok {
		return runtimecatalog.Definition{}, false
	}
	authMode, apiKey := "subscription", ""
	executionMode := protocol.ExecutionModeStrongIsolated
	if configured {
		authMode, apiKey = connection.AuthMode, connection.APIKey
		executionMode = connection.ExecutionMode
		adapterConfig.Model = connection.Model
		if !contains(catalog.supportedExecutionModes(adapterKey), executionMode) ||
			(executionMode == protocol.ExecutionModeHostTrusted && (adapterKey != cursor.AdapterKey || connection.AuthMode != "subscription" || !catalog.hostTrustedAvailable())) {
			return runtimecatalog.Definition{}, false
		}
	}
	model, fingerprint, err := adapterConfigurationIdentityFor(
		adapterKey, adapterConfig, catalog.config.Supervisor, authMode, apiKey, catalog.identityKey, executionMode,
	)
	if err != nil {
		return runtimecatalog.Definition{}, false
	}
	definition.EffectiveModel, definition.ConfigurationFingerprint = model, fingerprint
	definition.ConfigurationIdentity = func(executablePath, detectionKey, observedVersion string) (string, string, error) {
		return AdapterConfigurationIdentityForRuntime(
			adapterKey, adapterConfig, catalog.config.Supervisor, authMode, apiKey, catalog.identityKey,
			executablePath, detectionKey, observedVersion, executionMode,
		)
	}
	definition.AccountHome = adapterConfig.HomeDir
	definition.Transport = runtimecatalog.TransportManagedProcess
	definition.ExecutionMode = executionMode
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
		definition.AccountMetadata = cloneStringMap(definition.AccountMetadata)
		definition.AccountMetadata["transport"] = "managed_process"
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

func (catalog *ManagedCatalog) strongIsolationAvailable() bool {
	return catalog != nil && catalog.supported != nil && catalog.supported()
}

func (catalog *ManagedCatalog) hostTrustedAvailable() bool {
	return catalog != nil && catalog.config.HostTrustedEnabled && catalog.hostTrustedSupported != nil && catalog.hostTrustedSupported()
}

func (catalog *ManagedCatalog) supportedExecutionModes(adapterKey string) []string {
	definition, ok := providerconfig.Lookup(adapterKey)
	if !ok {
		return nil
	}
	result := make([]string, 0, len(definition.SupportedExecutionModes))
	for _, mode := range definition.SupportedExecutionModes {
		if mode == protocol.ExecutionModeHostTrusted && (adapterKey != cursor.AdapterKey || !catalog.hostTrustedAvailable()) {
			continue
		}
		if mode == protocol.ExecutionModeStrongIsolated && !catalog.strongIsolationAvailable() {
			continue
		}
		result = append(result, mode)
	}
	sort.Strings(result)
	return result
}

func cloneStringMap(values map[string]string) map[string]string {
	result := make(map[string]string, len(values)+1)
	for key, value := range values {
		result[key] = value
	}
	return result
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
