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
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
	"github.com/glnarayanan/navishai/runner/internal/scripted"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

var ErrPolicyDenied = errors.New("runner execution policy denied the request")

type Registry struct {
	config     Config
	catalog    *runtimecatalog.Catalog
	supervisor *supervisor.Supervisor
	now        func() time.Time
}

func NewRegistry(config Config, catalog *runtimecatalog.Catalog, now func() time.Time) (*Registry, error) {
	if config.WorkRoot == "" || catalog == nil {
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
	if anyLiveAdapter(config.Adapters) {
		processSupervisor, err = supervisor.New(config.Supervisor.build())
		if err != nil {
			return nil, fmt.Errorf("configure execution supervisor: %w", err)
		}
	}
	return &Registry{config: config, catalog: catalog, supervisor: processSupervisor, now: now}, nil
}

func (registry *Registry) Execute(ctx context.Context, request protocol.AdmissionRequest, emit func(protocol.CanonicalEvent) error) error {
	if request.Validate() != nil || emit == nil {
		return ErrPolicyDenied
	}
	if request.Routing.AdapterKey == "scripted" {
		return registry.executeScripted(ctx, request, emit)
	}
	adapterConfig, ok := registry.config.Adapters[request.Routing.AdapterKey]
	if !ok || !adapterConfig.Enabled || !adapterConfig.allows(request) || registry.supervisor == nil ||
		adapterConfig.HomeDir == "" || adapterConfig.EgressProfileKey == "" {
		return ErrPolicyDenied
	}
	installation, ok := registry.catalog.ResolveApproved(
		ctx, request.Routing.DetectionKey, registry.config.Supervisor.ApprovedExecutables,
	)
	if !ok || installation.AdapterKey != request.Routing.AdapterKey || installation.HealthStatus != "available" ||
		installation.CompatibilityStatus != "compatible" {
		return ErrPolicyDenied
	}
	workingDir, err := registry.workingDirectory(request.RunID)
	if err != nil {
		return err
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
			CodexHome: adapterConfig.HomeDir, Model: adapterConfig.Model, Prompt: prompt,
			EgressProfileKey: adapterConfig.EgressProfileKey,
		}, registry.supervisor, emit)
	case claude.AdapterKey:
		_, err = claude.New(registry.now).Execute(runContext, claude.Invocation{
			Admission: request, Executable: installation.ExecutablePath, WorkingDir: workingDir,
			ClaudeConfigDir: adapterConfig.HomeDir, Model: adapterConfig.Model, Prompt: prompt,
			EgressProfileKey: adapterConfig.EgressProfileKey,
		}, registry.supervisor, emit)
	case grok.AdapterKey:
		_, err = grok.New(registry.now).Execute(runContext, grok.Invocation{
			Admission: request, Executable: installation.ExecutablePath, WorkingDir: workingDir,
			GrokHome: adapterConfig.HomeDir, Model: adapterConfig.Model, Prompt: prompt,
			EgressProfileKey: adapterConfig.EgressProfileKey,
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

func (registry *Registry) executeScripted(ctx context.Context, request protocol.AdmissionRequest, emit func(protocol.CanonicalEvent) error) error {
	config, ok := registry.config.Adapters["scripted"]
	path := registry.config.Scripted[request.Routing.ProfileKey]
	if !ok || !config.Enabled || !config.allows(request) || path == "" ||
		ScriptedDetectionKey(path) != request.Routing.DetectionKey {
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

func anyLiveAdapter(configs map[string]AdapterConfig) bool {
	for key, config := range configs {
		if key != "scripted" && config.Enabled {
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

func ScriptedInstallations(config Config, checkedAt time.Time) []runtimecatalog.Installation {
	adapter, ok := config.Adapters["scripted"]
	if !ok || !adapter.Enabled {
		return nil
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
			Capabilities:    []string{"structured_output", "tool_calling"},
			MinimumVersion:  "1.0.0", MaximumVersion: "1.0.0", CompatibilityStatus: "compatible",
			HealthStatus: "available", CheckedAt: checkedAt.UTC().Format(time.RFC3339Nano),
		})
	}
	return installations
}

func contains(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}

func subset(values, allowed []string) bool {
	for _, value := range values {
		if !contains(allowed, value) {
			return false
		}
	}
	return true
}
