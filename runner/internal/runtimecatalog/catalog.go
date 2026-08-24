package runtimecatalog

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	maxVersionBytes = 8 * 1024
	probeTimeout    = 3 * time.Second
)

var ErrInvalidDefinition = errors.New("invalid runtime definition")
var semanticVersionPattern = regexp.MustCompile(`\b(\d+)\.(\d+)\.(\d+)\b`)

type Definition struct {
	AdapterKey       string
	ProtocolVersion  string
	ExecutableNames  []string
	VersionArguments []string
	Capabilities     []string
	MinimumVersion   string
	MaximumVersion   string
}

type Installation struct {
	DetectionKey          string            `json:"detection_key"`
	AdapterKey            string            `json:"adapter_key"`
	ProtocolVersion       string            `json:"protocol_version"`
	ExecutablePath        string            `json:"executable_path"`
	ExecutableVersion     string            `json:"executable_version"`
	AccountMetadata       map[string]string `json:"account_metadata"`
	Capabilities          []string          `json:"capabilities"`
	MinimumVersion        string            `json:"minimum_version"`
	MaximumVersion        string            `json:"maximum_version"`
	CompatibilityStatus   string            `json:"compatibility_status"`
	IncompatibilityReason string            `json:"incompatibility_reason"`
	HealthStatus          string            `json:"health_status"`
	CheckedAt             string            `json:"checked_at"`
}

type Catalog struct {
	definitions []Definition
	now         func() time.Time
}

func New(definitions []Definition, now func() time.Time) (*Catalog, error) {
	seen := make(map[string]bool, len(definitions))
	for _, definition := range definitions {
		if definition.AdapterKey == "" || definition.ProtocolVersion == "" || len(definition.ExecutableNames) == 0 ||
			len(definition.VersionArguments) == 0 || seen[definition.AdapterKey] {
			return nil, ErrInvalidDefinition
		}
		seen[definition.AdapterKey] = true
	}
	if now == nil {
		now = time.Now
	}
	return &Catalog{definitions: append([]Definition(nil), definitions...), now: now}, nil
}

func Empty() *Catalog {
	catalog, _ := New(nil, time.Now)
	return catalog
}

func (catalog *Catalog) Detect(ctx context.Context) []Installation {
	installations := make([]Installation, 0, len(catalog.definitions))
	for _, definition := range catalog.definitions {
		installation, ok := catalog.detect(ctx, definition)
		if ok {
			installations = append(installations, installation)
		}
	}
	sort.Slice(installations, func(i, j int) bool { return installations[i].AdapterKey < installations[j].AdapterKey })
	return installations
}

func (catalog *Catalog) detect(ctx context.Context, definition Definition) (Installation, bool) {
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
		return Installation{}, false
	}
	probeContext, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	command := exec.CommandContext(probeContext, resolved, definition.VersionArguments...)
	command.Env = []string{"HOME=" + os.TempDir(), "LANG=C.UTF-8", "PATH=" + os.Getenv("PATH")}
	output := &boundedBuffer{maximum: maxVersionBytes}
	command.Stdout, command.Stderr = output, output
	probeErr := command.Run()
	version := strings.TrimSpace(output.String())
	health := "available"
	compatibility, reason := compatibilityFor(version, definition.MinimumVersion, definition.MaximumVersion)
	if probeErr != nil || version == "" || output.overflowed {
		health, compatibility, reason = "unhealthy", "unknown", "The runtime version probe failed."
	}
	capabilities := append([]string(nil), definition.Capabilities...)
	sort.Strings(capabilities)
	return Installation{
		DetectionKey: detectionKey(definition.AdapterKey, resolved), AdapterKey: definition.AdapterKey,
		ProtocolVersion: definition.ProtocolVersion, ExecutablePath: resolved, ExecutableVersion: version,
		AccountMetadata: map[string]string{"authentication": "managed_on_runner"}, Capabilities: capabilities,
		MinimumVersion: definition.MinimumVersion, MaximumVersion: definition.MaximumVersion,
		CompatibilityStatus: compatibility, IncompatibilityReason: reason, HealthStatus: health,
		CheckedAt: catalog.now().UTC().Format(time.RFC3339Nano),
	}, true
}

func compatibilityFor(output, minimum, maximum string) (string, string) {
	version, versionOK := semanticVersion(output)
	minimumVersion, minimumOK := semanticVersion(minimum)
	maximumVersion, maximumOK := semanticVersion(maximum)
	if !versionOK || !minimumOK || !maximumOK {
		return "unknown", "Version compatibility has not been reported."
	}
	if compareVersions(version, minimumVersion) < 0 || compareVersions(version, maximumVersion) > 0 {
		return "incompatible", "The detected version is outside the maintained compatibility range."
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

func compareVersions(left, right [3]int) int {
	for index := range left {
		if left[index] < right[index] {
			return -1
		}
		if left[index] > right[index] {
			return 1
		}
	}
	return 0
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

func detectionKey(adapterKey, path string) string {
	digest := sha256.Sum256([]byte(adapterKey + "\x00" + path))
	return hex.EncodeToString(digest[:])
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
