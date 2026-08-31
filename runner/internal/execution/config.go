package execution

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

const (
	runtimeDefaultModel       = "runtime_default"
	configurationIdentityV1   = "navishai-runtime-configuration-v1"
	cursorSubscriptionAdapter = "cursor_acp_subscription"
)

type Config struct {
	WorkRoot   string                   `json:"work_root"`
	Scripted   map[string]string        `json:"scripted_fixtures"`
	Adapters   map[string]AdapterConfig `json:"adapters"`
	Supervisor SupervisorConfig         `json:"supervisor"`
}

type AdapterConfig struct {
	Enabled           bool     `json:"enabled"`
	HomeDir           string   `json:"home_dir"`
	Model             string   `json:"model"`
	EgressProfileKey  string   `json:"egress_profile_key"`
	Profiles          []string `json:"profiles"`
	Roles             []string `json:"roles"`
	Tools             []string `json:"tools"`
	DataClasses       []string `json:"data_classes"`
	MaxTimeoutSeconds int      `json:"max_timeout_seconds"`
	MaxSteps          int      `json:"max_steps"`
	MaxToolCalls      int      `json:"max_tool_calls"`
	MaxInputUnits     int      `json:"max_input_units"`
	MaxOutputUnits    int      `json:"max_output_units"`
}

type SupervisorConfig struct {
	HelperPath             string                `json:"helper_path"`
	NamespaceLauncherPath  string                `json:"namespace_launcher_path"`
	AllowedExecutableRoots []string              `json:"allowed_executable_roots"`
	ApprovedExecutables    []string              `json:"approved_executables"`
	AllowedWorkingRoots    []string              `json:"allowed_working_roots"`
	AllowedHomeRoots       []string              `json:"allowed_home_roots"`
	RuntimeReadRoots       []string              `json:"runtime_read_roots"`
	EgressProfiles         []EgressProfileConfig `json:"egress_profiles"`
	Limits                 SupervisorLimits      `json:"limits"`
}

type EgressProfileConfig struct {
	Key                  string            `json:"key"`
	Executable           string            `json:"executable"`
	UserNamespacePath    string            `json:"user_namespace_path"`
	NetworkNamespacePath string            `json:"network_namespace_path"`
	Environment          map[string]string `json:"environment"`
}

type SupervisorLimits struct {
	WallTimeSeconds int    `json:"wall_time_seconds"`
	CPUSeconds      uint64 `json:"cpu_seconds"`
	MemoryBytes     uint64 `json:"memory_bytes"`
	OpenFiles       uint64 `json:"open_files"`
	Processes       uint64 `json:"processes"`
	OutputBytes     int    `json:"output_bytes"`
	KillGraceMillis int    `json:"kill_grace_millis"`
}

type adapterConfigurationIdentity struct {
	Version           string                     `json:"version"`
	AdapterKey        string                     `json:"adapter_key"`
	Enabled           bool                       `json:"enabled"`
	HomeDir           string                     `json:"home_dir"`
	EffectiveModel    string                     `json:"effective_model"`
	AuthMode          string                     `json:"auth_mode,omitempty"`
	CredentialDigest  string                     `json:"credential_digest,omitempty"`
	EgressProfileKey  string                     `json:"egress_profile_key"`
	EgressExecutable  string                     `json:"egress_executable"`
	UserNamespace     string                     `json:"user_namespace"`
	NetworkNamespace  string                     `json:"network_namespace"`
	EgressEnvironment []configurationEnvironment `json:"egress_environment"`
	Profiles          []string                   `json:"profiles"`
	Roles             []string                   `json:"roles"`
	Tools             []string                   `json:"tools"`
	DataClasses       []string                   `json:"data_classes"`
	MaxTimeoutSeconds int                        `json:"max_timeout_seconds"`
	MaxSteps          int                        `json:"max_steps"`
	MaxToolCalls      int                        `json:"max_tool_calls"`
	MaxInputUnits     int                        `json:"max_input_units"`
	MaxOutputUnits    int                        `json:"max_output_units"`
}

type configurationEnvironment struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

func AdapterConfigurationIdentity(adapterKey string, adapter AdapterConfig, supervisor SupervisorConfig, key []byte) (string, string, error) {
	return adapterConfigurationIdentityFor(adapterKey, adapter, supervisor, "", "", key)
}

func adapterConfigurationIdentityFor(adapterKey string, adapter AdapterConfig, supervisor SupervisorConfig, authMode, apiKey string, key []byte) (string, string, error) {
	if err := protocol.ValidateSecret(key); err != nil {
		return "", "", err
	}
	model := adapter.Model
	if model == "" {
		model = runtimeDefaultModel
	}
	enabled := adapter.Enabled
	if authMode != "" {
		enabled = true
	}
	identity := adapterConfigurationIdentity{
		Version: "v1", AdapterKey: adapterKey, Enabled: enabled, HomeDir: adapter.HomeDir,
		EffectiveModel: model, AuthMode: authMode, EgressProfileKey: adapter.EgressProfileKey,
		Profiles: sortedCopy(adapter.Profiles), Roles: sortedCopy(adapter.Roles), Tools: sortedCopy(adapter.Tools),
		DataClasses: sortedCopy(adapter.DataClasses), MaxTimeoutSeconds: adapter.MaxTimeoutSeconds,
		MaxSteps: adapter.MaxSteps, MaxToolCalls: adapter.MaxToolCalls,
		MaxInputUnits: adapter.MaxInputUnits, MaxOutputUnits: adapter.MaxOutputUnits,
	}
	if apiKey != "" {
		credentialDigest := hmac.New(sha256.New, key)
		_, _ = credentialDigest.Write([]byte("navishai-provider-credential-v1\x00"))
		_, _ = credentialDigest.Write([]byte(apiKey))
		identity.CredentialDigest = hex.EncodeToString(credentialDigest.Sum(nil))
	}
	for _, profile := range supervisor.EgressProfiles {
		if profile.Key != adapter.EgressProfileKey {
			continue
		}
		identity.EgressExecutable = profile.Executable
		identity.UserNamespace = profile.UserNamespacePath
		identity.NetworkNamespace = profile.NetworkNamespacePath
		for key, value := range profile.Environment {
			identity.EgressEnvironment = append(identity.EgressEnvironment, configurationEnvironment{Key: key, Value: value})
		}
		sort.Slice(identity.EgressEnvironment, func(left, right int) bool {
			return identity.EgressEnvironment[left].Key < identity.EgressEnvironment[right].Key
		})
		break
	}
	encoded, err := json.Marshal(identity)
	if err != nil {
		return "", "", err
	}
	digest := hmac.New(sha256.New, key)
	_, _ = digest.Write([]byte(configurationIdentityV1 + "\x00"))
	_, _ = digest.Write(encoded)
	return model, hex.EncodeToString(digest.Sum(nil)), nil
}

func sortedCopy(values []string) []string {
	result := append([]string(nil), values...)
	sort.Strings(result)
	return result
}

func LoadConfig(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	if err := rejectDuplicateObjectKeys(data); err != nil {
		return Config{}, err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var config Config
	if err := decoder.Decode(&config); err != nil {
		return Config{}, err
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return Config{}, errors.New("runner execution config has trailing data")
	}
	if err := config.validate(); err != nil {
		return Config{}, err
	}
	return config, nil
}

var policyKeyPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)

var knownAdapters = map[string]bool{
	"scripted": true, "codex_subscription": true, "claude_subscription": true,
	"grok_acp_subscription": true, "cursor_acp_subscription": true,
}

var knownProfiles = values("workspace_default", "fast", "thorough")
var knownRoles = values(
	"support_coordinator", "support_investigator", "resolution_drafter", "support_reviewer",
	"account_analyst", "risk_investigator", "success_strategist", "success_reviewer",
)
var knownTools = values(
	"account_read", "case_read", "conversation_read", "draft_propose", "knowledge_search",
	"note_propose", "public_web_search", "review_record", "web_extract",
)
var knownDataClasses = values(
	"account_context", "approved_knowledge", "case_content", "customer_identity", "public_web_query", "retrieved_memory",
)

func (config Config) validate() error {
	if config.WorkRoot == "" {
		return errors.New("runner execution work_root is required")
	}
	egressKeys := make(map[string]bool, len(config.Supervisor.EgressProfiles))
	for _, profile := range config.Supervisor.EgressProfiles {
		if !policyKeyPattern.MatchString(profile.Key) || egressKeys[profile.Key] {
			return errors.New("runner execution config has an invalid egress profile key")
		}
		egressKeys[profile.Key] = true
	}
	for key, adapter := range config.Adapters {
		if key == cursorSubscriptionAdapter && adapter.Model != "" {
			return errors.New("runner Cursor adapter does not support explicit model selection")
		}
		if !knownAdapters[key] || !distinctPolicyKeys(adapter.Profiles, knownProfiles) ||
			!distinctPolicyKeys(adapter.Roles, knownRoles) || !distinctPolicyKeys(adapter.Tools, knownTools) ||
			!distinctPolicyKeys(adapter.DataClasses, knownDataClasses) ||
			adapter.MaxTimeoutSeconds < 30 || adapter.MaxTimeoutSeconds > 900 ||
			adapter.MaxSteps < 1 || adapter.MaxSteps > 20 || adapter.MaxToolCalls < 0 || adapter.MaxToolCalls > 50 ||
			adapter.MaxInputUnits < 1 || adapter.MaxInputUnits > 10_000_000 ||
			adapter.MaxOutputUnits < 1 || adapter.MaxOutputUnits > 10_000_000 {
			return fmt.Errorf("runner adapter %q has invalid policy", key)
		}
		if adapter.Enabled && (len(adapter.Profiles) == 0 || len(adapter.Roles) == 0 || len(adapter.DataClasses) == 0) {
			return fmt.Errorf("runner adapter %q has an empty enabled policy", key)
		}
		if adapter.Enabled && key != "scripted" && (adapter.HomeDir == "" || adapter.EgressProfileKey == "") {
			return fmt.Errorf("runner adapter %q requires home_dir and egress_profile_key", key)
		}
		if adapter.Enabled && key != "scripted" && !egressKeys[adapter.EgressProfileKey] {
			return fmt.Errorf("runner adapter %q references an unknown egress profile", key)
		}
	}
	scripted, scriptedEnabled := config.Adapters["scripted"]
	if scriptedEnabled && scripted.Enabled && len(config.Scripted) == 0 {
		return errors.New("enabled scripted adapter requires at least one fixture")
	}
	for profile, path := range config.Scripted {
		if !policyKeyPattern.MatchString(profile) || path == "" || !contains(scripted.Profiles, profile) {
			return errors.New("scripted fixture does not match the scripted adapter policy")
		}
	}
	return nil
}

func distinctPolicyKeys(items []string, allowed map[string]bool) bool {
	seen := make(map[string]bool, len(items))
	for _, value := range items {
		if !policyKeyPattern.MatchString(value) || !allowed[value] || seen[value] {
			return false
		}
		seen[value] = true
	}
	return true
}

func values(items ...string) map[string]bool {
	result := make(map[string]bool, len(items))
	for _, item := range items {
		result[item] = true
	}
	return result
}

func rejectDuplicateObjectKeys(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	var readValue func() error
	readValue = func() error {
		token, err := decoder.Token()
		if err != nil {
			return err
		}
		delimiter, ok := token.(json.Delim)
		if !ok {
			return nil
		}
		switch delimiter {
		case '{':
			seen := map[string]bool{}
			for decoder.More() {
				keyToken, err := decoder.Token()
				if err != nil {
					return err
				}
				key, ok := keyToken.(string)
				if !ok || seen[key] {
					return errors.New("runner execution config has a duplicate object key")
				}
				seen[key] = true
				if err := readValue(); err != nil {
					return err
				}
			}
		case '[':
			for decoder.More() {
				if err := readValue(); err != nil {
					return err
				}
			}
		default:
			return errors.New("runner execution config is malformed")
		}
		_, err = decoder.Token()
		return err
	}
	return readValue()
}

func (config SupervisorConfig) build() supervisor.Config {
	egressProfiles := make([]supervisor.EgressProfile, len(config.EgressProfiles))
	for index, profile := range config.EgressProfiles {
		egressProfiles[index] = supervisor.EgressProfile{
			Key: profile.Key, Executable: profile.Executable,
			UserNamespacePath: profile.UserNamespacePath, NetworkNamespacePath: profile.NetworkNamespacePath,
			Environment: profile.Environment,
		}
	}
	return supervisor.Config{
		HelperPath: config.HelperPath, NamespaceLauncherPath: config.NamespaceLauncherPath,
		AllowedExecutableRoots: config.AllowedExecutableRoots, ApprovedExecutables: config.ApprovedExecutables,
		AllowedWorkingRoots: config.AllowedWorkingRoots, AllowedHomeRoots: config.AllowedHomeRoots,
		RuntimeReadRoots: config.RuntimeReadRoots, EgressProfiles: egressProfiles,
		Limits: supervisor.Limits{
			WallTime:   time.Duration(config.Limits.WallTimeSeconds) * time.Second,
			CPUSeconds: config.Limits.CPUSeconds, MemoryBytes: config.Limits.MemoryBytes,
			OpenFiles: config.Limits.OpenFiles, Processes: config.Limits.Processes,
			OutputBytes: config.Limits.OutputBytes,
			KillGrace:   time.Duration(config.Limits.KillGraceMillis) * time.Millisecond,
		},
	}
}
