package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/adapters/claude"
	"github.com/glnarayanan/navishai/runner/internal/adapters/codex"
	"github.com/glnarayanan/navishai/runner/internal/adapters/cursor"
	"github.com/glnarayanan/navishai/runner/internal/adapters/grok"
	"github.com/glnarayanan/navishai/runner/internal/admission"
	"github.com/glnarayanan/navishai/runner/internal/execution"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
)

func TestHealthEndpoints(t *testing.T) {
	store, err := admission.OpenStore("")
	if err != nil {
		t.Fatal(err)
	}
	handler, err := newHandler([]byte("runner-test-secret-that-is-at-least-32-bytes"), store, "", time.Now)
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/livez", "/readyz"} {
		t.Run(path, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, path, nil)
			response := httptest.NewRecorder()

			handler.ServeHTTP(response, request)

			if response.Code != http.StatusOK {
				t.Fatalf("expected status %d, got %d", http.StatusOK, response.Code)
			}
			if contentType := response.Header().Get("Content-Type"); contentType != "application/json" {
				t.Fatalf("expected application/json, got %q", contentType)
			}
			if body := response.Body.String(); body != "{\"protocol_versions\":[\"v1\"],\"status\":\"ok\"}\n" {
				t.Fatalf("unexpected response body %q", body)
			}
		})
	}
}

func TestHandlerRequiresASecret(t *testing.T) {
	store, err := admission.OpenStore("")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := newHandler([]byte("short"), store, "", time.Now); err == nil {
		t.Fatal("expected a short secret to fail")
	}
}

func TestOnlyEligibleLiveAdaptersDeclareRuntimeTestCapability(t *testing.T) {
	for name, definition := range map[string]runtimecatalog.Definition{
		"Codex": codex.Definition(), "Claude": claude.Definition(),
		"Grok": grok.Definition(), "Cursor": cursor.Definition(),
	} {
		t.Run(name, func(t *testing.T) {
			if !hasCapability(definition.Capabilities, runtimecatalog.RuntimeTestCapability) {
				t.Fatalf("%s did not declare %q", name, runtimecatalog.RuntimeTestCapability)
			}
		})
	}

	fixture := filepath.Join("..", "..", "internal", "scripted", "testdata", "success.json")
	config := execution.Config{
		Scripted: map[string]string{"workspace_default": fixture},
		Adapters: map[string]execution.AdapterConfig{"scripted": {Enabled: true}},
	}
	installations, err := execution.ScriptedInstallations(
		config, []byte("runner-configuration-test-key-at-least-32-bytes"), time.Now(),
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(installations) != 1 || hasCapability(installations[0].Capabilities, runtimecatalog.RuntimeTestCapability) {
		t.Fatalf("scripted installation unexpectedly declared runtime testing: %#v", installations)
	}
}

func TestHandlerRegistersBothRuntimeDetectionVersions(t *testing.T) {
	secret := []byte("runner-test-secret-that-is-at-least-32-bytes")
	store, err := admission.OpenStore("")
	if err != nil {
		t.Fatal(err)
	}
	handler, err := newHandler(secret, store, "", time.Now)
	if err != nil {
		t.Fatal(err)
	}
	for _, endpoint := range []struct {
		path    string
		version string
	}{
		{path: runtimecatalog.LegacyDetectionPath, version: protocol.Version},
		{path: runtimecatalog.DetectionPath, version: runtimecatalog.DetectionVersion},
	} {
		t.Run(endpoint.version, func(t *testing.T) {
			body, _ := json.Marshal(map[string]string{
				"protocol_version": endpoint.version,
				"workspace_key":    "c9bb966b-1fe9-4304-bd51-404e4fd9a09c",
			})
			request := httptest.NewRequest(http.MethodPost, endpoint.path, bytes.NewReader(body))
			request.Header.Set("Content-Type", "application/json")
			timestamp := strconv.FormatInt(time.Now().Unix(), 10)
			request.Header.Set("X-NavishAI-Timestamp", timestamp)
			signature, err := protocol.Sign(secret, timestamp, http.MethodPost, endpoint.path, body)
			if err != nil {
				t.Fatal(err)
			}
			request.Header.Set("X-NavishAI-Signature", signature)
			response := httptest.NewRecorder()

			handler.ServeHTTP(response, request)

			if response.Code != http.StatusOK {
				t.Fatalf("expected status %d, got %d: %s", http.StatusOK, response.Code, response.Body.String())
			}
			var payload map[string]any
			if json.Unmarshal(response.Body.Bytes(), &payload) != nil || payload["protocol_version"] != endpoint.version {
				t.Fatalf("unexpected response %#v", payload)
			}
		})
	}
}

func TestTLSFiles(t *testing.T) {
	tests := []struct {
		name        string
		address     string
		environment map[string]string
		certificate string
		key         string
		wantError   bool
	}{
		{name: "cleartext IPv4 loopback", address: "127.0.0.1:8081", environment: map[string]string{}},
		{name: "cleartext IPv6 loopback", address: "[::1]:8081", environment: map[string]string{}},
		{name: "cleartext unspecified IPv4", address: "0.0.0.0:8081", environment: map[string]string{}, wantError: true},
		{name: "cleartext unspecified IPv6", address: "[::]:8081", environment: map[string]string{}, wantError: true},
		{name: "cleartext non-loopback", address: "192.0.2.10:8081", environment: map[string]string{}, wantError: true},
		{name: "certificate pair", address: "0.0.0.0:8081", environment: map[string]string{
			"NAVISHAI_RUNNER_TLS_CERT_FILE": "/run/secrets/runner.crt",
			"NAVISHAI_RUNNER_TLS_KEY_FILE":  "/run/secrets/runner.key",
		}, certificate: "/run/secrets/runner.crt", key: "/run/secrets/runner.key"},
		{name: "missing key", address: "127.0.0.1:8081", environment: map[string]string{
			"NAVISHAI_RUNNER_TLS_CERT_FILE": "/run/secrets/runner.crt",
		}, wantError: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			certificate, key, err := tlsFiles(test.address, func(name string) string { return test.environment[name] })
			if (err != nil) != test.wantError {
				t.Fatalf("unexpected error: %v", err)
			}
			if certificate != test.certificate || key != test.key {
				t.Fatalf("got certificate %q and key %q", certificate, key)
			}
		})
	}
}

func TestProviderVaultSecretUsesIndependentSecretAndValidatesFallback(t *testing.T) {
	shared := []byte("shared-runner-secret-that-is-at-least-32-bytes")
	vault := "independent-provider-vault-secret-at-least-32-bytes"
	resolved, err := providerVaultSecret(func(name string) string {
		if name == "NAVISHAI_RUNNER_PROVIDER_VAULT_SECRET" {
			return vault
		}
		return ""
	}, shared)
	if err != nil || string(resolved) != vault {
		t.Fatalf("independent vault secret was not selected: %q, err=%v", resolved, err)
	}
	resolved[0] = 'X'
	if vault[0] == 'X' {
		t.Fatal("vault secret was not copied")
	}
	fallback, err := providerVaultSecret(func(string) string { return "" }, shared)
	if err != nil || string(fallback) != string(shared) {
		t.Fatalf("shared-secret fallback failed: %q, err=%v", fallback, err)
	}
	if _, err := providerVaultSecret(func(string) string { return "short" }, shared); err == nil {
		t.Fatal("short configured vault secret was accepted")
	}
	if _, err := providerVaultSecret(func(string) string { return "" }, []byte("short")); err == nil {
		t.Fatal("short shared-secret fallback was accepted")
	}
}

func hasCapability(capabilities []string, wanted string) bool {
	for _, capability := range capabilities {
		if capability == wanted {
			return true
		}
	}
	return false
}
