package execution

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters"
	"github.com/glnarayanan/navishai/runner/internal/adapters/claude"
	"github.com/glnarayanan/navishai/runner/internal/adapters/codex"
	"github.com/glnarayanan/navishai/runner/internal/adapters/cursor"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/providerapi"
	"github.com/glnarayanan/navishai/runner/internal/providerconfig"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

const (
	workspaceOne = "c9bb966b-1fe9-4304-bd51-404e4fd9a09c"
	workspaceTwo = "3d07f334-88ef-4fe4-a640-421e3ba79921"
)

type fakeModelDiscoveryProcessRunner struct {
	result        supervisor.Result
	err           error
	request       supervisor.Request
	calls         int
	waitForCancel bool
}

type fakeProviderAPI struct {
	models          []providerapi.ModelOption
	err             error
	adapter         string
	apiKey          string
	calls           int
	ctx             context.Context
	generation      providerapi.GenerationResult
	generationErr   error
	generationCalls int
	prompt          string
	model           string
	outputTokens    int
}

func (client *fakeProviderAPI) DiscoverModels(ctx context.Context, adapterKey, apiKey string) ([]providerapi.ModelOption, error) {
	client.calls++
	client.ctx, client.adapter, client.apiKey = ctx, adapterKey, apiKey
	return client.models, client.err
}

func (client *fakeProviderAPI) Generate(ctx context.Context, adapterKey, apiKey, model, prompt string, outputTokens int) (providerapi.GenerationResult, error) {
	client.generationCalls++
	client.ctx, client.adapter, client.apiKey = ctx, adapterKey, apiKey
	client.model, client.prompt, client.outputTokens = model, prompt, outputTokens
	return client.generation, client.generationErr
}

func (runner *fakeModelDiscoveryProcessRunner) Run(ctx context.Context, request supervisor.Request) (supervisor.Result, error) {
	runner.calls++
	runner.request = request
	if runner.waitForCancel {
		<-ctx.Done()
		return supervisor.Result{TimedOut: true}, ctx.Err()
	}
	return runner.result, runner.err
}

func newFakeModelDiscoveryRegistry(t *testing.T, adapterKey, authMode string, runner adapters.ProcessRunner) (*Registry, string) {
	t.Helper()
	home := t.TempDir()
	store, err := providerconfig.OpenStore("", testConfigurationIdentityKey)
	if err != nil {
		t.Fatal(err)
	}
	model, apiKey := "", ""
	if authMode == "api_key" {
		model, apiKey = "gpt-test", "sk-model-discovery-test-value"
	}
	if _, err := store.Configure(workspaceOne, adapterKey, authMode, model, apiKey); err != nil {
		t.Fatal(err)
	}
	executableName := "codex"
	if adapterKey == cursor.AdapterKey {
		executableName = "cursor-agent"
	}
	executableDirectory := t.TempDir()
	executable := filepath.Join(executableDirectory, executableName)
	if err := os.WriteFile(executable, []byte("model-discovery-test-fixture"), 0o700); err != nil {
		t.Fatal(err)
	}
	config := Config{
		WorkRoot: t.TempDir(),
		Adapters: map[string]AdapterConfig{adapterKey: {
			Enabled: true, HomeDir: home, EgressProfileKey: "model_api",
			Profiles: []string{"workspace_default"}, Roles: []string{"support_investigator"},
			DataClasses: []string{"case_content"},
		}},
		Supervisor: SupervisorConfig{ApprovedExecutables: []string{executable}, EgressProfiles: []EgressProfileConfig{{Key: "model_api"}}},
	}
	registry := &Registry{config: config, providers: store, processRunner: runner, supported: func() bool { return true }}
	return registry, home
}

func TestDiscoverModelsUsesBoundedFakeRunnerAndCodexAuthHome(t *testing.T) {
	runner := &fakeModelDiscoveryProcessRunner{result: supervisor.Result{
		ExitCode:       0,
		StandardOutput: `{"models":[{"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","visibility":"list","default":true}]}`,
	}}
	registry, home := newFakeModelDiscoveryRegistry(t, codex.AdapterKey, "subscription", runner)
	request := httptest.NewRequest(http.MethodPost, providerconfig.ModelsPath, nil)
	result := registry.DiscoverModels(request, workspaceOne, codex.AdapterKey)
	if result.Status != providerconfig.ModelDiscoveryAvailable || len(result.Models) != 1 || result.Models[0].ID != "gpt-5.6-sol" || !result.Models[0].Default {
		t.Fatalf("unexpected Codex discovery result: %#v", result)
	}
	if runner.calls != 1 {
		t.Fatalf("fake discovery runner received unexpected calls: %d", runner.calls)
	}
	if !reflectRequestArguments(runner.request.Arguments, []string{"debug", "models"}) || runner.request.Executable == "" || runner.request.WorkingDir == "" || runner.request.EgressProfileKey != "model_api" {
		t.Fatalf("unexpected bounded process request: %#v", runner.request)
	}
	if runner.request.HomeDir != home || runner.request.Credentials["CODEX_HOME"] != home {
		t.Fatalf("Codex subscription home was not propagated consistently: home=%q credentials=%#v", runner.request.HomeDir, runner.request.Credentials)
	}
	if _, err := os.Stat(runner.request.WorkingDir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("discovery working directory was not removed after the fake run: %q err=%v", runner.request.WorkingDir, err)
	}
}

func TestDiscoverModelsUsesDirectProviderAPIForAPIKeysWithoutProcessExecution(t *testing.T) {
	for _, adapterKey := range []string{codex.AdapterKey, claude.AdapterKey} {
		t.Run(adapterKey, func(t *testing.T) {
			runner := &fakeModelDiscoveryProcessRunner{}
			registry, _ := newFakeModelDiscoveryRegistry(t, adapterKey, "api_key", runner)
			client := &fakeProviderAPI{models: []providerapi.ModelOption{{ID: "future-model", Label: "Future Model", Default: true}}}
			registry.providerAPI = client
			result := registry.DiscoverModels(httptest.NewRequest(http.MethodPost, providerconfig.ModelsPath, nil), workspaceOne, adapterKey)
			if result.Status != providerconfig.ModelDiscoveryAvailable || len(result.Models) != 1 || result.Models[0].ID != "future-model" || !result.Models[0].Default {
				t.Fatalf("unexpected API-key discovery result: %#v", result)
			}
			var deadline time.Time
			hasDeadline := false
			if client.ctx != nil {
				deadline, hasDeadline = client.ctx.Deadline()
			}
			if client.calls != 1 || client.adapter != adapterKey || client.apiKey != "sk-model-discovery-test-value" || client.ctx == nil || client.ctx.Err() != nil || !hasDeadline || deadline.Sub(time.Now()) > modelDiscoveryTimeout {
				t.Fatalf("direct provider API did not receive bounded request context and stored credentials: calls=%d adapter=%q context_nil=%t", client.calls, client.adapter, client.ctx == nil)
			}
			if runner.calls != 0 {
				t.Fatalf("API-key discovery invoked the process runner: %d", runner.calls)
			}
		})
	}
}

func TestDiscoverModelsAPIKeyCanBeSavedBeforeModelSelection(t *testing.T) {
	store, err := providerconfig.OpenStore("", testConfigurationIdentityKey)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Configure(workspaceOne, claude.AdapterKey, "api_key", "", "sk-model-discovery-test-value"); err != nil {
		t.Fatalf("blank-model API-key connection was not saved: %v", err)
	}
	client := &fakeProviderAPI{models: []providerapi.ModelOption{{ID: "claude-future", Label: "Claude Future"}}}
	registry := &Registry{
		config: Config{Adapters: map[string]AdapterConfig{
			claude.AdapterKey: {Profiles: []string{"profile"}, Roles: []string{"role"}, DataClasses: []string{"data"}},
		}},
		providers: store, providerAPI: client,
	}
	result := registry.DiscoverModels(httptest.NewRequest(http.MethodPost, providerconfig.ModelsPath, nil), workspaceOne, claude.AdapterKey)
	if result.Status != providerconfig.ModelDiscoveryAvailable || len(result.Models) != 1 || client.calls != 1 {
		t.Fatalf("saved incomplete API-key connection did not discover models: result=%#v calls=%d", result, client.calls)
	}
}

func TestBlankAPIKeyConnectionRemainsCatalogAndExecutionFailClosed(t *testing.T) {
	directory := t.TempDir()
	home := filepath.Join(directory, "claude-home")
	if err := os.Mkdir(home, 0o700); err != nil {
		t.Fatal(err)
	}
	executable := filepath.Join(directory, "claude")
	if err := os.WriteFile(executable, []byte("not-launched"), 0o700); err != nil {
		t.Fatal(err)
	}
	store, err := providerconfig.OpenStore("", testConfigurationIdentityKey)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Configure(workspaceOne, claude.AdapterKey, "api_key", "", "sk-awaiting-model-selection"); err != nil {
		t.Fatal(err)
	}
	config := Config{
		WorkRoot: t.TempDir(),
		Adapters: map[string]AdapterConfig{claude.AdapterKey: {
			HomeDir: home, EgressProfileKey: "model_api", Profiles: []string{"workspace_default"},
			Roles: []string{"support_investigator"}, DataClasses: []string{"case_content"},
		}},
		Supervisor: SupervisorConfig{
			ApprovedExecutables: []string{executable}, EgressProfiles: []EgressProfileConfig{{Key: "model_api"}},
		},
	}
	catalog, err := NewManagedCatalog(config, store, testConfigurationIdentityKey, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	catalog.supported = func() bool { return true }
	if installations := catalog.DetectWorkspace(context.Background(), workspaceOne); len(installations) != 0 {
		t.Fatalf("incomplete API-key connection produced a catalog installation: %#v", installations)
	}
	if _, ok := catalog.ResolveApprovedWorkspace(context.Background(), workspaceOne, strings.Repeat("a", 64), []string{executable}); ok {
		t.Fatal("incomplete API-key connection resolved as an approved runtime")
	}
	availability := catalog.ProviderAvailability(httptest.NewRequest(http.MethodGet, providerconfig.CatalogPath, nil), workspaceOne, claude.AdapterKey)
	if availability.Available || availability.HealthStatus != "unavailable" {
		t.Fatalf("incomplete API-key connection reported availability: %#v", availability)
	}

	runner := &fakeModelDiscoveryProcessRunner{}
	client := &fakeProviderAPI{}
	registry := &Registry{
		config: config, catalog: catalog, providers: store, processRunner: runner, providerAPI: client,
		supported: func() bool { return true },
	}
	if _, err := registry.TestRuntime(context.Background(), runtimecatalog.TestRequest{
		WorkspaceKey: workspaceOne, RequestID: workspaceTwo,
		DetectionKey: strings.Repeat("a", 64), ConfigurationFingerprint: strings.Repeat("b", 64),
	}); !errors.Is(err, runtimecatalog.ErrTestConfigurationChanged) {
		t.Fatalf("incomplete API-key connection did not fail closed for runtime test: %v", err)
	}
	request := executionRequest(t)
	request.WorkspaceKey = workspaceOne
	request.Routing.AdapterKey = claude.AdapterKey
	request.Routing.ExecutionMode = protocol.ExecutionModeHostTrusted
	request.Routing.IsolationPolicy = protocol.IsolationPolicyHostTrustedAllowed
	if err := registry.Execute(context.Background(), request, func(protocol.CanonicalEvent) error { return nil }); !errors.Is(err, ErrPolicyDenied) {
		t.Fatalf("incomplete API-key connection did not fail closed for execution: %v", err)
	}
	if runner.calls != 0 || client.calls != 0 {
		t.Fatalf("fail-closed catalog/runtime paths invoked an external seam: process_calls=%d api_calls=%d", runner.calls, client.calls)
	}
}

func TestDiscoverModelsSubscriptionNeverUsesProviderAPI(t *testing.T) {
	runner := &fakeModelDiscoveryProcessRunner{result: supervisor.Result{ExitCode: 0, StandardOutput: `{"models":[{"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","visibility":"list"}]}`}}
	registry, _ := newFakeModelDiscoveryRegistry(t, codex.AdapterKey, "subscription", runner)
	client := &fakeProviderAPI{models: []providerapi.ModelOption{{ID: "should-not-be-used", Label: "Should not be used"}}}
	registry.providerAPI = client
	result := registry.DiscoverModels(httptest.NewRequest(http.MethodPost, providerconfig.ModelsPath, nil), workspaceOne, codex.AdapterKey)
	if result.Status != providerconfig.ModelDiscoveryAvailable || client.calls != 0 || runner.calls != 1 {
		t.Fatalf("subscription discovery crossed provider API/process boundary: result=%#v api_calls=%d process_calls=%d", result, client.calls, runner.calls)
	}
}

func TestDiscoverModelsUnsupportedSupervisorFailsClosedBeforeProcess(t *testing.T) {
	runner := &fakeModelDiscoveryProcessRunner{}
	registry, _ := newFakeModelDiscoveryRegistry(t, codex.AdapterKey, "subscription", runner)
	registry.supported = func() bool { return false }
	result := registry.DiscoverModels(httptest.NewRequest(http.MethodPost, providerconfig.ModelsPath, nil), workspaceOne, codex.AdapterKey)
	if result.Status != providerconfig.ModelDiscoveryFailed || runner.calls != 0 {
		t.Fatalf("unsupported supervisor did not fail closed before process discovery: result=%#v calls=%d", result, runner.calls)
	}
}

func TestDiscoverModelsReturnsUnsupportedWithoutAdapterSpec(t *testing.T) {
	request := httptest.NewRequest(http.MethodPost, providerconfig.ModelsPath, nil)
	for _, adapterKey := range []string{providerconfig.ClaudeAdapterKey, providerconfig.GrokAdapterKey, "scripted", "unknown"} {
		result := (&Registry{}).DiscoverModels(request, workspaceOne, adapterKey)
		if result.Status != providerconfig.ModelDiscoveryUnsupported || len(result.Models) != 0 {
			t.Fatalf("adapter %q was not explicitly unsupported: %#v", adapterKey, result)
		}
	}
}

func TestDiscoverModelsFailsClosedForWorkspaceOrProcessFailures(t *testing.T) {
	tests := []struct {
		name   string
		result supervisor.Result
		err    error
	}{
		{name: "nonzero exit", result: supervisor.Result{ExitCode: 1}},
		{name: "timeout", result: supervisor.Result{TimedOut: true}},
		{name: "canceled", result: supervisor.Result{Canceled: true}},
		{name: "output limit", result: supervisor.Result{OutputExceeded: true}},
		{name: "runner error", err: errors.New("fake process failure")},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			runner := &fakeModelDiscoveryProcessRunner{result: test.result, err: test.err}
			registry, _ := newFakeModelDiscoveryRegistry(t, codex.AdapterKey, "subscription", runner)
			result := registry.DiscoverModels(httptest.NewRequest(http.MethodPost, providerconfig.ModelsPath, nil), workspaceOne, codex.AdapterKey)
			if result.Status != providerconfig.ModelDiscoveryFailed || len(result.Models) != 0 {
				t.Fatalf("process failure was not bounded failed: %#v", result)
			}
		})
	}

	runner := &fakeModelDiscoveryProcessRunner{}
	registry, _ := newFakeModelDiscoveryRegistry(t, codex.AdapterKey, "subscription", runner)
	registry.config.Supervisor.ApprovedExecutables = nil
	result := registry.DiscoverModels(httptest.NewRequest(http.MethodPost, providerconfig.ModelsPath, nil), workspaceOne, codex.AdapterKey)
	if result.Status != providerconfig.ModelDiscoveryFailed || runner.calls != 0 {
		t.Fatalf("unavailable installation did not fail without execution: result=%#v calls=%d", result, runner.calls)
	}

	runner = &fakeModelDiscoveryProcessRunner{}
	registry, _ = newFakeModelDiscoveryRegistry(t, codex.AdapterKey, "subscription", runner)
	result = registry.DiscoverModels(httptest.NewRequest(http.MethodPost, providerconfig.ModelsPath, nil), workspaceTwo, codex.AdapterKey)
	if result.Status != providerconfig.ModelDiscoveryFailed || runner.calls != 0 {
		t.Fatalf("unconfigured workspace was not isolated: result=%#v calls=%d", result, runner.calls)
	}
}

func TestDiscoverModelsRejectsMalformedBoundedOutputAndCanceledContext(t *testing.T) {
	outputs := []string{
		`{"models":[{"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","visibility":"list"},{"slug":"gpt-5.6-sol","display_name":"Duplicate","visibility":"list"}]}`,
		`{"models":[{"slug":"gpt-5.6-sol\n","display_name":"GPT-5.6-Sol","visibility":"list"}]}`,
		`{"models":[{"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","visibility":"hide"}]}`,
		`{"models":[{"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","visibility":"bogus"}]}`,
	}
	for _, output := range outputs {
		runner := &fakeModelDiscoveryProcessRunner{result: supervisor.Result{ExitCode: 0, StandardOutput: output}}
		registry, _ := newFakeModelDiscoveryRegistry(t, codex.AdapterKey, "subscription", runner)
		result := registry.DiscoverModels(httptest.NewRequest(http.MethodPost, providerconfig.ModelsPath, nil), workspaceOne, codex.AdapterKey)
		if result.Status != providerconfig.ModelDiscoveryFailed {
			t.Fatalf("malformed output was accepted: output=%s result=%#v", output, result)
		}
	}

	runner := &fakeModelDiscoveryProcessRunner{result: supervisor.Result{ExitCode: 0, StandardOutput: "should-not-be-used"}, waitForCancel: true}
	registry, _ := newFakeModelDiscoveryRegistry(t, codex.AdapterKey, "subscription", runner)
	request := httptest.NewRequest(http.MethodPost, providerconfig.ModelsPath, nil)
	ctx, cancel := context.WithCancel(request.Context())
	cancel()
	result := registry.DiscoverModels(request.WithContext(ctx), workspaceOne, codex.AdapterKey)
	if result.Status != providerconfig.ModelDiscoveryFailed || runner.calls != 1 {
		t.Fatalf("canceled discovery was not failed closed: result=%#v calls=%d", result, runner.calls)
	}
}

func TestDiscoverModelsRejectsOversizedCodexOutput(t *testing.T) {
	runner := &fakeModelDiscoveryProcessRunner{result: supervisor.Result{
		ExitCode: 0, StandardOutput: strings.Repeat("x", adapters.MaxModelDiscoveryOutputBytes+1),
	}}
	registry, _ := newFakeModelDiscoveryRegistry(t, codex.AdapterKey, "subscription", runner)
	result := registry.DiscoverModels(httptest.NewRequest(http.MethodPost, providerconfig.ModelsPath, nil), workspaceOne, codex.AdapterKey)
	if result.Status != providerconfig.ModelDiscoveryFailed {
		t.Fatalf("oversized discovery output was accepted: %#v", result)
	}
}

func TestDiscoverModelsUsesCursorListModelContract(t *testing.T) {
	runner := &fakeModelDiscoveryProcessRunner{result: supervisor.Result{ExitCode: 0, StandardOutput: "composer-2.5\ngpt-5.5-medium\n"}}
	registry, home := newFakeModelDiscoveryRegistry(t, cursor.AdapterKey, "subscription", runner)
	result := registry.DiscoverModels(httptest.NewRequest(http.MethodPost, providerconfig.ModelsPath, nil), workspaceOne, cursor.AdapterKey)
	if result.Status != providerconfig.ModelDiscoveryAvailable || len(result.Models) != 2 || result.Models[0].ID != "composer-2.5" || result.Models[1].Label != "gpt-5.5-medium" {
		t.Fatalf("unexpected Cursor discovery result: %#v", result)
	}
	if !reflectRequestArguments(runner.request.Arguments, []string{"--list-models"}) || runner.request.HomeDir != home {
		t.Fatalf("unexpected Cursor discovery request: %#v", runner.request)
	}
}

func reflectRequestArguments(actual, expected []string) bool {
	if len(actual) != len(expected) {
		return false
	}
	for index := range actual {
		if actual[index] != expected[index] {
			return false
		}
	}
	return true
}
