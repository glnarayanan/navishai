package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters/claude"
	"github.com/glnarayanan/navishai/runner/internal/adapters/codex"
	"github.com/glnarayanan/navishai/runner/internal/adapters/cursor"
	"github.com/glnarayanan/navishai/runner/internal/adapters/grok"
	"github.com/glnarayanan/navishai/runner/internal/admission"
	"github.com/glnarayanan/navishai/runner/internal/events"
	"github.com/glnarayanan/navishai/runner/internal/execution"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/providerconfig"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
	"github.com/glnarayanan/navishai/runner/internal/websearch"
)

func main() {
	address := os.Getenv("NAVISHAI_RUNNER_BIND_ADDRESS")
	if address == "" {
		address = "127.0.0.1:8081"
	}
	secret := []byte(os.Getenv("NAVISHAI_RUNNER_SHARED_SECRET"))
	statePath := os.Getenv("NAVISHAI_RUNNER_STATE_PATH")
	if statePath == "" {
		statePath = "tmp/runner-admissions.json"
	}
	store, err := admission.OpenStore(statePath)
	if err != nil {
		log.Fatalf("open runner admission state: %v", err)
	}
	searchStatePath := os.Getenv("NAVISHAI_WEB_SEARCH_STATE_PATH")
	if searchStatePath == "" {
		searchStatePath = statePath + ".web-search"
	}
	runtimeTestStore, err := runtimecatalog.OpenTestStore(statePath + ".runtime-tests")
	if err != nil {
		log.Fatalf("open runtime test state: %v", err)
	}
	executionConfigPath := os.Getenv("NAVISHAI_RUNNER_EXECUTION_CONFIG")
	controlPlaneAddress := os.Getenv("NAVISHAI_CONTROL_PLANE_ADDRESS")
	if executionConfigPath == "" || controlPlaneAddress == "" {
		log.Fatal("NAVISHAI_RUNNER_EXECUTION_CONFIG and NAVISHAI_CONTROL_PLANE_ADDRESS are required")
	}
	executionConfig, err := execution.LoadConfig(executionConfigPath)
	if err != nil {
		log.Fatalf("load runner execution config: %v", err)
	}
	vaultSecret, err := providerVaultSecret(os.Getenv, secret)
	if err != nil {
		log.Fatal(err)
	}
	providerStore, err := providerconfig.OpenStore(statePath+".providers", vaultSecret)
	if err != nil {
		log.Fatalf("open provider state: %v", err)
	}
	catalog, err := execution.NewManagedCatalog(executionConfig, providerStore, secret, time.Now)
	if err != nil {
		log.Fatalf("configure runtime catalog: %v", err)
	}
	registry, err := execution.NewRegistryWithProviders(executionConfig, catalog, providerStore, secret, time.Now)
	if err != nil {
		log.Fatalf("configure runner execution: %v", err)
	}
	handler, err := newManagedHandlerWithRuntimeTesterAndStoreAndDiscovery(secret, store, searchStatePath, catalog, registry, runtimeTestStore, providerStore, catalog, registry, time.Now)
	if err != nil {
		log.Fatalf("configure runner protocol: %v", err)
	}
	allowPrivateControlPlaneHTTP := os.Getenv("NAVISHAI_CONTROL_PLANE_ALLOW_PRIVATE_HTTP") == "true"
	eventSink, err := events.New(controlPlaneAddress, secret, allowPrivateControlPlaneHTTP, time.Now)
	if err != nil {
		log.Fatalf("configure runner event delivery: %v", err)
	}
	dispatcher, err := execution.NewDispatcher(store, eventSink, registry, time.Now)
	if err != nil {
		log.Fatalf("configure runner dispatcher: %v", err)
	}
	go func() {
		if err := dispatcher.Run(context.Background()); err != nil {
			log.Fatalf("runner dispatcher stopped: %v", err)
		}
	}()

	server := &http.Server{
		Addr:              address,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      50 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	certificate, key, err := tlsFiles(address, os.Getenv)
	if err != nil {
		log.Fatal(err)
	}
	if certificate != "" {
		log.Printf("NavishAI runner listening with TLS on %s", address)
		log.Fatal(server.ListenAndServeTLS(certificate, key))
	}
	log.Printf("NavishAI runner listening on %s", address)
	log.Fatal(server.ListenAndServe())
}

func providerVaultSecret(getenv func(string) string, sharedSecret []byte) ([]byte, error) {
	configured := []byte(getenv("NAVISHAI_RUNNER_PROVIDER_VAULT_SECRET"))
	if len(configured) > 0 {
		if len(configured) < 32 {
			return nil, fmt.Errorf("NAVISHAI_RUNNER_PROVIDER_VAULT_SECRET must contain at least 32 bytes")
		}
		return append([]byte(nil), configured...), nil
	}
	if protocol.ValidateSecret(sharedSecret) != nil {
		return nil, fmt.Errorf("NAVISHAI_RUNNER_SHARED_SECRET must contain at least 32 bytes when the provider vault secret is unset")
	}
	return append([]byte(nil), sharedSecret...), nil
}

func tlsFiles(address string, getenv func(string) string) (string, string, error) {
	certificate := getenv("NAVISHAI_RUNNER_TLS_CERT_FILE")
	key := getenv("NAVISHAI_RUNNER_TLS_KEY_FILE")
	if (certificate == "") != (key == "") {
		return "", "", fmt.Errorf("NAVISHAI_RUNNER_TLS_CERT_FILE and NAVISHAI_RUNNER_TLS_KEY_FILE must be set together")
	}
	if certificate == "" {
		host, _, err := net.SplitHostPort(address)
		if err != nil {
			return "", "", fmt.Errorf("invalid NAVISHAI_RUNNER_BIND_ADDRESS: %w", err)
		}
		if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
			return "", "", fmt.Errorf("cleartext runner bind must use a loopback IP address")
		}
	}
	return certificate, key, nil
}

func newHandler(secret []byte, store *admission.Store, searchStatePath string, now func() time.Time) (http.Handler, error) {
	catalog, err := runtimeCatalog(now, nil)
	if err != nil {
		return nil, err
	}
	return newHandlerWithCatalog(secret, store, searchStatePath, catalog, now)
}

func runtimeCatalog(now func() time.Time, installations []runtimecatalog.Installation) (*runtimecatalog.Catalog, error) {
	return runtimecatalog.NewWithInstallations([]runtimecatalog.Definition{
		codex.Definition(), claude.Definition(), grok.Definition(), cursor.Definition(),
	}, installations, now)
}

func configuredRuntimeCatalog(config execution.Config, configurationIdentityKey []byte, now func() time.Time) (*runtimecatalog.Catalog, error) {
	definitions := []runtimecatalog.Definition{}
	available := map[string]runtimecatalog.Definition{
		codex.AdapterKey: codex.Definition(), claude.AdapterKey: claude.Definition(),
		grok.AdapterKey: grok.Definition(), cursor.AdapterKey: cursor.Definition(),
	}
	for key, definition := range available {
		if config.Adapters[key].Enabled {
			model, fingerprint, err := execution.AdapterConfigurationIdentity(
				key, config.Adapters[key], config.Supervisor, configurationIdentityKey, definition.ExecutionMode,
			)
			if err != nil {
				return nil, err
			}
			definition.EffectiveModel, definition.ConfigurationFingerprint = model, fingerprint
			definitions = append(definitions, definition)
		}
	}
	scriptedInstallations, err := execution.ScriptedInstallations(config, configurationIdentityKey, now())
	if err != nil {
		return nil, err
	}
	return runtimecatalog.NewWithInstallations(
		definitions, scriptedInstallations, now,
	)
}

func newHandlerWithCatalog(secret []byte, store *admission.Store, searchStatePath string, catalog runtimecatalog.WorkspaceCatalog, now func() time.Time) (http.Handler, error) {
	return newHandlerWithRuntimeTester(secret, store, searchStatePath, catalog, unavailableRuntimeTester{}, now)
}

type unavailableRuntimeTester struct{}

func (unavailableRuntimeTester) TestRuntime(context.Context, runtimecatalog.TestRequest) (runtimecatalog.TestResult, error) {
	return runtimecatalog.TestResult{}, fmt.Errorf("runtime test is unavailable")
}

func newHandlerWithRuntimeTester(secret []byte, store *admission.Store, searchStatePath string, catalog runtimecatalog.WorkspaceCatalog, tester runtimecatalog.RuntimeTester, now func() time.Time) (http.Handler, error) {
	runtimeTestStore, err := runtimecatalog.OpenTestStore("")
	if err != nil {
		return nil, err
	}
	return newHandlerWithRuntimeTesterAndStore(secret, store, searchStatePath, catalog, tester, runtimeTestStore, now)
}

func newHandlerWithRuntimeTesterAndStore(secret []byte, store *admission.Store, searchStatePath string, catalog runtimecatalog.WorkspaceCatalog, tester runtimecatalog.RuntimeTester, runtimeTestStore *runtimecatalog.TestStore, now func() time.Time) (http.Handler, error) {
	providerStore, err := providerconfig.OpenStore("", secret)
	if err != nil {
		return nil, err
	}
	return newManagedHandlerWithRuntimeTesterAndStore(secret, store, searchStatePath, catalog, tester, runtimeTestStore, providerStore, unavailableProviderStatus{}, now)
}

type unavailableProviderStatus struct{}

func (unavailableProviderStatus) ProviderAvailability(*http.Request, string, string) providerconfig.Availability {
	return providerconfig.Availability{HealthStatus: "unavailable"}
}

func newManagedHandlerWithRuntimeTesterAndStore(secret []byte, store *admission.Store, searchStatePath string, catalog runtimecatalog.WorkspaceCatalog, tester runtimecatalog.RuntimeTester, runtimeTestStore *runtimecatalog.TestStore, providerStore *providerconfig.Store, providerStatus providerconfig.StatusSource, now func() time.Time) (http.Handler, error) {
	return newManagedHandlerWithRuntimeTesterAndStoreAndDiscovery(secret, store, searchStatePath, catalog, tester, runtimeTestStore, providerStore, providerStatus, nil, now)
}

func newManagedHandlerWithRuntimeTesterAndStoreAndDiscovery(secret []byte, store *admission.Store, searchStatePath string, catalog runtimecatalog.WorkspaceCatalog, tester runtimecatalog.RuntimeTester, runtimeTestStore *runtimecatalog.TestStore, providerStore *providerconfig.Store, providerStatus providerconfig.StatusSource, discovery providerconfig.ModelDiscoverySource, now func() time.Time) (http.Handler, error) {
	admissionHandler, err := admission.NewHandler(secret, store, now)
	if err != nil {
		return nil, fmt.Errorf("create admission handler: %w", err)
	}
	runtimeHandler, err := runtimecatalog.NewHandler(secret, catalog, now)
	if err != nil {
		return nil, fmt.Errorf("create runtime detection handler: %w", err)
	}
	legacyRuntimeHandler, err := runtimecatalog.NewLegacyHandler(secret, catalog, now)
	if err != nil {
		return nil, fmt.Errorf("create legacy runtime detection handler: %w", err)
	}
	testHandler, err := runtimecatalog.NewTestHandlerWithStore(secret, tester, runtimeTestStore, now)
	if err != nil {
		return nil, fmt.Errorf("create runtime test handler: %w", err)
	}
	providerHandler, err := providerconfig.NewHandlerWithDiscovery(secret, providerStore, providerStatus, discovery, now)
	if err != nil {
		return nil, fmt.Errorf("create provider handler: %w", err)
	}
	searchStore, err := websearch.OpenStore(searchStatePath)
	if err != nil {
		return nil, fmt.Errorf("open web search state: %w", err)
	}
	searchProvider, err := configureSearchProvider(os.Getenv)
	if err != nil {
		return nil, err
	}
	searchHandler, err := websearch.NewHandler(secret, searchProvider, searchStore, now)
	if err != nil {
		return nil, fmt.Errorf("create web search handler: %w", err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /livez", healthHandler)
	mux.HandleFunc("GET /readyz", healthHandler)
	mux.Handle("POST "+protocol.AdmissionPath, admissionHandler)
	mux.Handle("POST "+runtimecatalog.LegacyDetectionPath, legacyRuntimeHandler)
	mux.Handle("POST "+runtimecatalog.DetectionPath, runtimeHandler)
	mux.Handle("POST "+runtimecatalog.TestPath, testHandler)
	mux.Handle("POST "+providerconfig.CatalogPath, providerHandler)
	mux.Handle("POST "+providerconfig.ConfigurePath, providerHandler)
	mux.Handle("POST "+providerconfig.ModelsPath, providerHandler)
	mux.Handle("POST "+providerconfig.RemovePath, providerHandler)
	mux.Handle("POST "+providerconfig.PurgePath, providerHandler)
	mux.Handle("POST "+websearch.Path, searchHandler)
	return mux, nil
}

func healthHandler(response http.ResponseWriter, _ *http.Request) {
	response.Header().Set("Content-Type", "application/json")
	response.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(response).Encode(map[string]any{
		"status": "ok", "protocol_versions": []string{protocol.Version},
		"admission_versions": []string{protocol.AdmissionVersion},
	})
}

// configureSearchProvider selects the runner's public-web search adapter from the
// environment. SearXNG stays the self-hosted default; Exa and Tavily are optional
// hosted providers whose API key is held only on the runner.
func configureSearchProvider(getenv func(string) string) (websearch.Provider, error) {
	switch providerKey := getenv("NAVISHAI_WEB_SEARCH_PROVIDER"); providerKey {
	case "":
		return nil, nil
	case websearch.SearXNGKey:
		provider, err := websearch.NewSearXNG(getenv("NAVISHAI_SEARXNG_URL"), nil)
		if err != nil {
			return nil, fmt.Errorf("configure SearXNG: %w", err)
		}
		return provider, nil
	case websearch.ExaKey:
		provider, err := websearch.NewExa(getenv("NAVISHAI_EXA_API_KEY"), getenv("NAVISHAI_EXA_URL"), nil)
		if err != nil {
			return nil, fmt.Errorf("configure Exa: %w", err)
		}
		return provider, nil
	case websearch.TavilyKey:
		provider, err := websearch.NewTavily(getenv("NAVISHAI_TAVILY_API_KEY"), getenv("NAVISHAI_TAVILY_URL"), nil)
		if err != nil {
			return nil, fmt.Errorf("configure Tavily: %w", err)
		}
		return provider, nil
	default:
		return nil, fmt.Errorf("unsupported web search provider %q", providerKey)
	}
}
