package runtimecatalog

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

const (
	RuntimeTestCapability = "runtime_test"
	maxVersionBytes       = 8 * 1024
	probeTimeout          = 3 * time.Second
)

type Transport string

const (
	TransportBuiltInHTTPS   Transport = "built_in_https"
	TransportManagedProcess Transport = "managed_process"
)

var ErrInvalidDefinition = errors.New("invalid runtime definition")
var semanticVersionPattern = regexp.MustCompile(`\b(\d+)\.(\d+)\.(\d+)\b`)
var environmentNamePattern = regexp.MustCompile(`^[A-Z][A-Z0-9_]{0,63}$`)
var policyKeyPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)
var lowerHexPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type Definition struct {
	AdapterKey               string
	ProtocolVersion          string
	ExecutableNames          []string
	VersionArguments         []string
	AccountArguments         []string
	AccountMarker            string
	AccountValidator         func(string) bool
	AccountEnvironment       []string
	AccountEnvironmentValues map[string]string
	AccountHome              string
	AccountMetadata          map[string]string
	Capabilities             []string
	Transport                Transport
	ExecutionMode            string
	EffectiveModel           string
	ConfigurationFingerprint string
	// ConfigurationIdentity is evaluated after the executable has been
	// resolved and its version probe has completed. It lets managed adapters
	// bind the identity to the exact runtime evidence used for this report.
	ConfigurationIdentity func(executablePath, detectionKey, observedVersion string) (string, string, error)
	MinimumVersion        string
	MaximumVersion        string
}

type Installation struct {
	DetectionKey             string            `json:"detection_key"`
	AdapterKey               string            `json:"adapter_key"`
	ProtocolVersion          string            `json:"protocol_version"`
	ExecutablePath           string            `json:"executable_path"`
	ExecutableVersion        string            `json:"executable_version"`
	AccountMetadata          map[string]string `json:"account_metadata"`
	Capabilities             []string          `json:"capabilities"`
	Transport                Transport         `json:"transport"`
	ExecutionMode            string            `json:"execution_mode"`
	EffectiveModel           string            `json:"effective_model"`
	ConfigurationFingerprint string            `json:"configuration_fingerprint"`
	MinimumVersion           string            `json:"minimum_version"`
	MaximumVersion           string            `json:"maximum_version"`
	CompatibilityStatus      string            `json:"compatibility_status"`
	IncompatibilityReason    string            `json:"incompatibility_reason"`
	HealthStatus             string            `json:"health_status"`
	CheckedAt                string            `json:"checked_at"`
}

type Catalog struct {
	definitions []Definition
	static      []Installation
	now         func() time.Time
}

type WorkspaceCatalog interface {
	DetectWorkspace(context.Context, string) []Installation
	ResolveApprovedWorkspace(context.Context, string, string, []string) (Installation, bool)
}

func New(definitions []Definition, now func() time.Time) (*Catalog, error) {
	return NewWithInstallations(definitions, nil, now)
}

func NewWithInstallations(definitions []Definition, installations []Installation, now func() time.Time) (*Catalog, error) {
	seen := make(map[string]bool, len(definitions))
	for _, definition := range definitions {
		if definition.AdapterKey == "" || definition.ProtocolVersion == "" || len(definition.ExecutableNames) == 0 ||
			len(definition.VersionArguments) == 0 || seen[definition.AdapterKey] ||
			!validTransport(definition.Transport) ||
			!validExecutionMode(definition.ExecutionMode) ||
			!validConfigurationIdentity(definition.EffectiveModel, definition.ConfigurationFingerprint) ||
			(len(definition.AccountArguments) > 0 && ((definition.AccountMarker == "") == (definition.AccountValidator == nil) ||
				len(definition.AccountMetadata) == 0)) ||
			(len(definition.AccountEnvironment) > 0 && len(definition.AccountArguments) == 0) ||
			(len(definition.AccountEnvironmentValues) > 0 && len(definition.AccountArguments) == 0) ||
			!validEnvironmentNames(definition.AccountEnvironment) || !validEnvironmentValues(definition.AccountEnvironmentValues) ||
			(definition.AccountHome != "" && !filepath.IsAbs(definition.AccountHome)) {
			return nil, ErrInvalidDefinition
		}
		seen[definition.AdapterKey] = true
	}
	installationKeys := make(map[string]bool, len(installations))
	for _, installation := range installations {
		if !validInstallation(installation) || installationKeys[installation.DetectionKey] {
			return nil, ErrInvalidDefinition
		}
		installationKeys[installation.DetectionKey] = true
	}
	if now == nil {
		now = time.Now
	}
	return &Catalog{
		definitions: append([]Definition(nil), definitions...),
		static:      append([]Installation(nil), installations...), now: now,
	}, nil
}

func validInstallation(installation Installation) bool {
	if !lowerHexPattern.MatchString(installation.DetectionKey) || !policyKeyPattern.MatchString(installation.AdapterKey) ||
		installation.ProtocolVersion == "" || !filepath.IsAbs(installation.ExecutablePath) || installation.ExecutableVersion == "" ||
		!validTransport(installation.Transport) ||
		!validExecutionMode(installation.ExecutionMode) ||
		installation.CompatibilityStatus != "compatible" || installation.IncompatibilityReason != "" ||
		installation.HealthStatus != "available" || len(installation.Capabilities) == 0 ||
		!validConfigurationIdentity(installation.EffectiveModel, installation.ConfigurationFingerprint) ||
		installation.AccountMetadata == nil || len(installation.AccountMetadata) == 0 {
		return false
	}
	if _, ok := semanticVersion(installation.MinimumVersion); !ok {
		return false
	}
	if _, ok := semanticVersion(installation.MaximumVersion); !ok {
		return false
	}
	if _, err := time.Parse(time.RFC3339Nano, installation.CheckedAt); err != nil {
		return false
	}
	capabilities := make(map[string]bool, len(installation.Capabilities))
	for _, capability := range installation.Capabilities {
		if !policyKeyPattern.MatchString(capability) || capabilities[capability] {
			return false
		}
		capabilities[capability] = true
	}
	return true
}

func validTransport(value Transport) bool {
	switch value {
	case TransportBuiltInHTTPS, TransportManagedProcess:
		return true
	default:
		return false
	}
}

func validExecutionMode(value string) bool {
	switch value {
	case protocol.ExecutionModeBounded, protocol.ExecutionModeHostTrusted, protocol.ExecutionModeStrongIsolated:
		return true
	default:
		return false
	}
}

func validConfigurationIdentity(model, fingerprint string) bool {
	return len(model) > 0 && len(model) <= 200 && !strings.ContainsAny(model, "\r\n\x00") && lowerHexPattern.MatchString(fingerprint)
}

// ValidObservedVersion accepts bounded version evidence without imposing a
// numeric compatibility ceiling. Maintained version fields remain part of a
// detection report, while future releases are evaluated by the behavioral
// connection test rather than rejected by a stale range.
func ValidObservedVersion(value string) bool {
	if len(value) == 0 || len(value) > maxVersionBytes || !utf8.ValidString(value) {
		return false
	}
	for _, runeValue := range value {
		if unicode.IsControl(runeValue) {
			return false
		}
	}
	_, ok := semanticVersion(value)
	return ok
}

func validEnvironmentNames(values []string) bool {
	seen := make(map[string]bool, len(values))
	for _, value := range values {
		if !environmentNamePattern.MatchString(value) || strings.HasPrefix(value, "NAVISHAI_") || seen[value] {
			return false
		}
		seen[value] = true
	}
	return true
}

func validEnvironmentValues(values map[string]string) bool {
	for key, value := range values {
		if !environmentNamePattern.MatchString(key) || strings.HasPrefix(key, "NAVISHAI_") || len(value) > 16*1024 || strings.ContainsRune(value, 0) {
			return false
		}
	}
	return true
}

func Empty() *Catalog {
	catalog, _ := New(nil, time.Now)
	return catalog
}

func (catalog *Catalog) Detect(ctx context.Context) []Installation {
	installations := append([]Installation{}, catalog.static...)
	for _, definition := range catalog.definitions {
		installation, ok := catalog.detect(ctx, definition)
		if ok {
			installations = append(installations, installation)
		}
	}
	sort.Slice(installations, func(i, j int) bool { return installations[i].AdapterKey < installations[j].AdapterKey })
	return installations
}

// DetectApproved reports only installations whose resolved executable path is
// present in the deployment policy. No runtime probe is started until the path
// has passed that check.
func (catalog *Catalog) DetectApproved(ctx context.Context, approvedPaths []string) []Installation {
	approved := make(map[string]bool, len(approvedPaths))
	for _, path := range approvedPaths {
		resolved, err := approvedExecutable(path)
		if err != nil {
			return nil
		}
		approved[resolved] = true
	}
	installations := make([]Installation, 0, len(catalog.static)+len(catalog.definitions))
	for _, installation := range catalog.static {
		if approved[installation.ExecutablePath] {
			installations = append(installations, installation)
		}
	}
	for _, definition := range catalog.definitions {
		resolved, ok := resolveExecutable(definition)
		if !ok || !approved[resolved] {
			continue
		}
		installations = append(installations, catalog.detectResolved(ctx, definition, resolved))
	}
	sort.Slice(installations, func(i, j int) bool { return installations[i].AdapterKey < installations[j].AdapterKey })
	return installations
}

func (catalog *Catalog) DetectWorkspace(ctx context.Context, _ string) []Installation {
	return catalog.Detect(ctx)
}

func (catalog *Catalog) ResolveApproved(ctx context.Context, wantedKey string, approvedPaths []string) (Installation, bool) {
	approved := make(map[string]bool, len(approvedPaths))
	for _, path := range approvedPaths {
		resolved, err := approvedExecutable(path)
		if err != nil {
			return Installation{}, false
		}
		approved[resolved] = true
	}
	for _, installation := range catalog.static {
		if approved[installation.ExecutablePath] && installation.DetectionKey == wantedKey &&
			detectionKey(installation.AdapterKey, installation.ExecutablePath) == wantedKey {
			return installation, true
		}
	}
	for _, definition := range catalog.definitions {
		resolved, ok := resolveExecutable(definition)
		if !ok || !approved[resolved] || detectionKey(definition.AdapterKey, resolved) != wantedKey {
			continue
		}
		installation := catalog.detectResolved(ctx, definition, resolved)
		if installation.DetectionKey == wantedKey {
			return installation, true
		}
		return Installation{}, false
	}
	return Installation{}, false
}

func (catalog *Catalog) ResolveApprovedWorkspace(ctx context.Context, _ string, wantedKey string, approvedPaths []string) (Installation, bool) {
	return catalog.ResolveApproved(ctx, wantedKey, approvedPaths)
}

func (catalog *Catalog) detect(ctx context.Context, definition Definition) (Installation, bool) {
	resolved, ok := resolveExecutable(definition)
	if !ok {
		return Installation{}, false
	}
	return catalog.detectResolved(ctx, definition, resolved), true
}

func resolveExecutable(definition Definition) (string, bool) {
	path := ""
	for _, name := range definition.ExecutableNames {
		candidate, err := exec.LookPath(name)
		if err == nil {
			path = candidate
			break
		}
	}
	resolved, err := approvedExecutable(path)
	if err != nil {
		return "", false
	}
	return resolved, true
}

func (catalog *Catalog) detectResolved(ctx context.Context, definition Definition, resolved string) Installation {
	version, probeErr, versionOverflowed := probe(ctx, resolved, definition.VersionArguments, nil, "")
	health := "available"
	compatibility, reason := compatibilityFor(version, definition.MinimumVersion, definition.MaximumVersion)
	if probeErr != nil || version == "" || versionOverflowed {
		health, compatibility, reason = "unhealthy", "unknown", "The runtime version probe failed."
	}
	detection := detectionKey(definition.AdapterKey, resolved)
	effectiveModel, configurationFingerprint := definition.EffectiveModel, definition.ConfigurationFingerprint
	if definition.ConfigurationIdentity != nil && compatibility == "compatible" {
		model, fingerprint, identityErr := definition.ConfigurationIdentity(resolved, detection, version)
		if identityErr != nil || !validConfigurationIdentity(model, fingerprint) {
			health, compatibility, reason = "unhealthy", "unknown", "The runtime configuration identity could not be computed."
		} else {
			effectiveModel, configurationFingerprint = model, fingerprint
		}
	}
	accountMetadata := map[string]string{"authentication": "managed_on_runner"}
	if len(definition.AccountArguments) > 0 {
		environment := cloneEnvironment(definition.AccountEnvironmentValues)
		for _, key := range definition.AccountEnvironment {
			if value := os.Getenv(key); value != "" {
				environment[key] = value
			}
		}
		accountOutput, accountErr, overflowed := probe(ctx, resolved, definition.AccountArguments, environment, definition.AccountHome)
		authenticated := strings.Contains(accountOutput, definition.AccountMarker)
		if definition.AccountValidator != nil {
			authenticated = definition.AccountValidator(accountOutput)
		}
		if accountErr != nil || overflowed || !authenticated {
			health = "unhealthy"
			accountMetadata = cloneMetadata(definition.AccountMetadata)
			accountMetadata["authentication"] = "not_authenticated"
		} else {
			accountMetadata = cloneMetadata(definition.AccountMetadata)
		}
	}
	capabilities := append([]string(nil), definition.Capabilities...)
	sort.Strings(capabilities)
	return Installation{
		DetectionKey: detection, AdapterKey: definition.AdapterKey,
		ProtocolVersion: definition.ProtocolVersion, ExecutablePath: resolved, ExecutableVersion: version,
		AccountMetadata: accountMetadata, Capabilities: capabilities, Transport: definition.Transport,
		ExecutionMode:  definition.ExecutionMode,
		EffectiveModel: effectiveModel, ConfigurationFingerprint: configurationFingerprint,
		MinimumVersion: definition.MinimumVersion, MaximumVersion: definition.MaximumVersion,
		CompatibilityStatus: compatibility, IncompatibilityReason: reason, HealthStatus: health,
		CheckedAt: catalog.now().UTC().Format(time.RFC3339Nano),
	}
}

func probe(ctx context.Context, executable string, arguments []string, accountEnvironment map[string]string, configuredHome string) (string, error, bool) {
	probeContext, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	command := exec.CommandContext(probeContext, executable, arguments...)
	home := os.TempDir()
	if configuredHome != "" {
		home = configuredHome
	} else if len(accountEnvironment) > 0 && os.Getenv("HOME") != "" {
		home = os.Getenv("HOME")
	}
	command.Env = []string{"HOME=" + home, "LANG=C.UTF-8", "PATH=" + os.Getenv("PATH")}
	keys := make([]string, 0, len(accountEnvironment))
	for key := range accountEnvironment {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		command.Env = append(command.Env, key+"="+accountEnvironment[key])
	}
	output := &boundedBuffer{maximum: maxVersionBytes}
	command.Stdout, command.Stderr = output, output
	err := command.Run()
	return strings.TrimSpace(output.String()), err, output.overflowed
}

func cloneEnvironment(values map[string]string) map[string]string {
	result := make(map[string]string, len(values))
	for key, value := range values {
		result[key] = value
	}
	return result
}

func cloneMetadata(metadata map[string]string) map[string]string {
	result := make(map[string]string, len(metadata))
	for key, value := range metadata {
		result[key] = value
	}
	return result
}

func compatibilityFor(output string, _ string, _ string) (string, string) {
	if !ValidObservedVersion(output) {
		return "unknown", "Version compatibility has not been reported."
	}
	return "compatible", ""
}

func semanticVersion(value string) ([3]int, bool) {
	match := semanticVersionPattern.FindStringSubmatch(value)
	if len(match) != 4 {
		return [3]int{}, false
	}
	var version [3]int
	for index := range version {
		parsed, err := strconv.Atoi(match[index+1])
		if err != nil {
			return [3]int{}, false
		}
		version[index] = parsed
	}
	return version, true
}

func approvedExecutable(path string) (string, error) {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil || !filepath.IsAbs(resolved) {
		return "", ErrInvalidDefinition
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 || info.Mode()&(os.ModeSetuid|os.ModeSetgid) != 0 {
		return "", ErrInvalidDefinition
	}
	return filepath.Clean(resolved), nil
}

// ResolveApprovedExecutable validates an explicitly approved executable path
// without probing or launching the runtime.
func ResolveApprovedExecutable(path string) (string, error) {
	return approvedExecutable(path)
}

func detectionKey(adapterKey, path string) string {
	file, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer file.Close()
	digest := sha256.New()
	_, _ = digest.Write([]byte(adapterKey + "\x00" + path + "\x00"))
	if _, err := io.Copy(digest, file); err != nil {
		return ""
	}
	return hex.EncodeToString(digest.Sum(nil))
}

type boundedBuffer struct {
	bytes.Buffer
	maximum    int
	overflowed bool
}

func (buffer *boundedBuffer) Write(value []byte) (int, error) {
	remaining := buffer.maximum - buffer.Len()
	if remaining <= 0 {
		buffer.overflowed = true
		return len(value), nil
	}
	written := len(value)
	if len(value) > remaining {
		value = value[:remaining]
		buffer.overflowed = true
	}
	_, _ = buffer.Buffer.Write(value)
	return written, nil
}
