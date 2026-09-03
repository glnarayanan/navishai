package execution

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"regexp"
	"slices"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/providerconfig"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
)

const (
	providerAPIContractVersion = "navishai-provider-api-v1"
	providerAPIVersionEvidence = "NavishAI provider API 1.0.0"
	providerAPIMinimumVersion  = "1.0.0"
	providerAPIMaximumVersion  = "1.0.0"
	providerAPIOpenAIPath      = "/navishai/provider-api/openai"
	providerAPIAnthropicPath   = "/navishai/provider-api/anthropic"
)

var providerAPIWorkspacePattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

type providerAPIIdentity struct {
	Contract          string                   `json:"contract"`
	WorkspaceKey      string                   `json:"workspace_key"`
	AdapterKey        string                   `json:"adapter_key"`
	AuthMode          string                   `json:"auth_mode"`
	Transport         runtimecatalog.Transport `json:"transport"`
	ExecutionMode     string                   `json:"execution_mode"`
	CredentialDigest  string                   `json:"credential_digest"`
	EffectiveModel    string                   `json:"effective_model"`
	Profiles          []string                 `json:"profiles"`
	Roles             []string                 `json:"roles"`
	Tools             []string                 `json:"tools"`
	DataClasses       []string                 `json:"data_classes"`
	MaxTimeoutSeconds int                      `json:"max_timeout_seconds"`
	MaxSteps          int                      `json:"max_steps"`
	MaxToolCalls      int                      `json:"max_tool_calls"`
	MaxInputUnits     int                      `json:"max_input_units"`
	MaxOutputUnits    int                      `json:"max_output_units"`
}

func providerAPIInstallation(workspaceKey, adapterKey string, adapter AdapterConfig, connection providerconfig.Connection, identityKey []byte, now time.Time) (runtimecatalog.Installation, bool) {
	if !providerAPIWorkspacePattern.MatchString(workspaceKey) || !isDirectProviderAPIAdapter(adapterKey) ||
		!providerAPIAdapterPolicyValid(adapterKey, adapter) || connection.AuthMode != "api_key" ||
		connection.ExecutionMode != protocol.ExecutionModeBounded ||
		!validProviderAPIText(connection.APIKey, 16*1024) || !validProviderAPIText(connection.Model, 200) ||
		strings.TrimSpace(connection.APIKey) != connection.APIKey || strings.TrimSpace(connection.Model) != connection.Model ||
		!providerAPIIdentityKeyValid(identityKey) {
		return runtimecatalog.Installation{}, false
	}
	model, fingerprint, err := providerAPIConfigurationIdentity(workspaceKey, adapterKey, adapter, connection, identityKey)
	if err != nil {
		return runtimecatalog.Installation{}, false
	}
	path := providerAPIExecutablePath(adapterKey)
	if path == "" {
		return runtimecatalog.Installation{}, false
	}
	return runtimecatalog.Installation{
		DetectionKey: detectionKeyForProviderAPI(adapterKey), AdapterKey: adapterKey,
		ProtocolVersion: protocol.Version, ExecutablePath: path, ExecutableVersion: providerAPIVersionEvidence,
		AccountMetadata: map[string]string{"authentication": "api_key", "transport": "built_in_https"},
		Transport:       runtimecatalog.TransportBuiltInHTTPS, ExecutionMode: protocol.ExecutionModeBounded,
		Capabilities: []string{
			runtimecatalog.RuntimeTestCapability, runtimecatalog.ProviderGenerationCapability, "structured_output",
		},
		EffectiveModel: model, ConfigurationFingerprint: fingerprint,
		MinimumVersion: providerAPIMinimumVersion, MaximumVersion: providerAPIMaximumVersion,
		CompatibilityStatus: "compatible", HealthStatus: "available",
		CheckedAt: now.UTC().Format(time.RFC3339Nano),
	}, true
}

func providerAPIExecutablePath(adapterKey string) string {
	switch adapterKey {
	case "codex_subscription":
		return providerAPIOpenAIPath
	case "claude_subscription":
		return providerAPIAnthropicPath
	default:
		return ""
	}
}

func isDirectProviderAPIInstallation(installation runtimecatalog.Installation, connection providerconfig.Connection) bool {
	return isDirectProviderAPIAdapter(installation.AdapterKey) && connection.AuthMode == "api_key" &&
		connection.ExecutionMode == protocol.ExecutionModeBounded && installation.ExecutionMode == protocol.ExecutionModeBounded &&
		installation.DetectionKey == detectionKeyForProviderAPI(installation.AdapterKey) &&
		installation.ExecutablePath == providerAPIExecutablePath(installation.AdapterKey) &&
		installation.ExecutableVersion == providerAPIVersionEvidence &&
		installation.Transport == runtimecatalog.TransportBuiltInHTTPS &&
		slices.Contains(installation.Capabilities, runtimecatalog.ProviderGenerationCapability)
}

func detectionKeyForProviderAPI(adapterKey string) string {
	path := providerAPIExecutablePath(adapterKey)
	if path == "" {
		return ""
	}
	digest := sha256.Sum256([]byte(providerAPIContractVersion + "\x00" + adapterKey + "\x00" + path))
	return hex.EncodeToString(digest[:])
}

func providerAPIConfigurationIdentity(workspaceKey, adapterKey string, adapter AdapterConfig, connection providerconfig.Connection, identityKey []byte) (string, string, error) {
	if !providerAPIWorkspacePattern.MatchString(workspaceKey) || !isDirectProviderAPIAdapter(adapterKey) ||
		!providerAPIAdapterPolicyValid(adapterKey, adapter) || connection.AuthMode != "api_key" ||
		connection.ExecutionMode != protocol.ExecutionModeBounded ||
		!validProviderAPIText(connection.APIKey, 16*1024) || !validProviderAPIText(connection.Model, 200) ||
		strings.TrimSpace(connection.APIKey) != connection.APIKey || strings.TrimSpace(connection.Model) != connection.Model ||
		!providerAPIIdentityKeyValid(identityKey) {
		return "", "", errors.New("invalid direct provider API identity")
	}
	credentialDigest := hmac.New(sha256.New, identityKey)
	_, _ = credentialDigest.Write([]byte("navishai-provider-api-credential-v1\x00"))
	_, _ = credentialDigest.Write([]byte(connection.APIKey))
	identity := providerAPIIdentity{
		Contract: providerAPIContractVersion, WorkspaceKey: workspaceKey, AdapterKey: adapterKey,
		AuthMode: connection.AuthMode, Transport: runtimecatalog.TransportBuiltInHTTPS, ExecutionMode: connection.ExecutionMode,
		CredentialDigest: hex.EncodeToString(credentialDigest.Sum(nil)),
		EffectiveModel:   connection.Model, Profiles: sortedCopy(adapter.Profiles), Roles: sortedCopy(adapter.Roles),
		Tools: sortedCopy(adapter.Tools), DataClasses: sortedCopy(adapter.DataClasses),
		MaxTimeoutSeconds: adapter.MaxTimeoutSeconds, MaxSteps: adapter.MaxSteps, MaxToolCalls: adapter.MaxToolCalls,
		MaxInputUnits: adapter.MaxInputUnits, MaxOutputUnits: adapter.MaxOutputUnits,
	}
	encoded, err := json.Marshal(identity)
	if err != nil {
		return "", "", err
	}
	digest := hmac.New(sha256.New, identityKey)
	_, _ = digest.Write([]byte("navishai-provider-api-configuration-v1\x00"))
	_, _ = digest.Write(encoded)
	return connection.Model, hex.EncodeToString(digest.Sum(nil)), nil
}

func providerAPIIdentityKeyValid(identityKey []byte) bool {
	return protocol.ValidateSecret(identityKey) == nil
}

func providerAPIAdapterPolicyValid(adapterKey string, adapter AdapterConfig) bool {
	return isDirectProviderAPIAdapter(adapterKey) && len(adapter.Profiles) > 0 && len(adapter.Roles) > 0 &&
		len(adapter.DataClasses) > 0 && adapter.MaxTimeoutSeconds >= 30 && adapter.MaxTimeoutSeconds <= 900 &&
		adapter.MaxSteps >= 1 && adapter.MaxSteps <= 20 && adapter.MaxToolCalls >= 0 && adapter.MaxToolCalls <= 50 &&
		adapter.MaxInputUnits >= 1 && adapter.MaxInputUnits <= 10_000_000 &&
		adapter.MaxOutputUnits >= 1 && adapter.MaxOutputUnits <= 10_000_000
}

func validProviderAPIText(value string, maximum int) bool {
	if value == "" || len(value) > maximum || !utf8.ValidString(value) {
		return false
	}
	for _, character := range value {
		if unicode.IsControl(character) {
			return false
		}
	}
	return true
}
