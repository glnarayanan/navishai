package providerconfig

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var testSecret = []byte("provider-store-test-secret-that-is-at-least-32-bytes")

const (
	workspaceOne = "c9bb966b-1fe9-4304-bd51-404e4fd9a09c"
	workspaceTwo = "3d07f334-88ef-4fe4-a640-421e3ba79921"
)

func TestStoreEncryptsSecretsAndAtomicallyRetainsWorkspaceConnections(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "runner.json.providers")
	store, err := OpenStore(path, testSecret)
	if err != nil {
		t.Fatal(err)
	}
	secretOne := "sk-openai-secret-value"
	secretTwo := "sk-anthropic-secret-value"
	if _, err := store.Configure(workspaceOne, CodexAdapterKey, "api_key", "gpt-5", secretOne); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Configure(workspaceTwo, ClaudeAdapterKey, "api_key", "claude-sonnet", secretTwo); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(data, []byte(secretOne)) || bytes.Contains(data, []byte(secretTwo)) || bytes.Contains(data, []byte(workspaceOne)) {
		t.Fatalf("encrypted state exposed plaintext: %s", data)
	}
	if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("provider state mode = %v, err = %v", info, err)
	}
	temporary, err := filepath.Glob(filepath.Join(directory, ".providers-*"))
	if err != nil || len(temporary) != 0 {
		t.Fatalf("atomic write left temporary files: %v, err = %v", temporary, err)
	}
	reopened, err := OpenStore(path, testSecret)
	if err != nil {
		t.Fatal(err)
	}
	connectionOne, ok := reopened.Get(workspaceOne, CodexAdapterKey)
	if !ok || connectionOne.APIKey != secretOne || connectionOne.Model != "gpt-5" {
		t.Fatalf("first workspace connection was not retained: %#v", connectionOne)
	}
	if _, ok := reopened.Get(workspaceOne, ClaudeAdapterKey); ok {
		t.Fatal("second workspace connection leaked into the first workspace")
	}
	connectionTwo, ok := reopened.Get(workspaceTwo, ClaudeAdapterKey)
	if !ok || connectionTwo.APIKey != secretTwo {
		t.Fatalf("second workspace connection was not retained: %#v", connectionTwo)
	}
}

func TestStoreRetainsBlankAPIKeyOnlyForSameKeyModeAndRemovesOneAdapter(t *testing.T) {
	store, err := OpenStore("", testSecret)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Configure(workspaceOne, CodexAdapterKey, "api_key", "gpt-old", "sk-existing-value"); err != nil {
		t.Fatal(err)
	}
	updated, err := store.Configure(workspaceOne, CodexAdapterKey, "api_key", "gpt-new", "")
	if err != nil || updated.APIKey != "sk-existing-value" || updated.Model != "gpt-new" {
		t.Fatalf("blank edit did not retain existing key: %#v, err = %v", updated, err)
	}
	if _, err := store.Configure(workspaceOne, ClaudeAdapterKey, "api_key", "sonnet", ""); err == nil {
		t.Fatal("new API-key connection accepted a blank secret")
	}
	if _, err := store.Configure(workspaceOne, CodexAdapterKey, "subscription", "", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Configure(workspaceOne, CodexAdapterKey, "api_key", "gpt-new", ""); err == nil {
		t.Fatal("auth-mode switch reused a discarded API key")
	}
	if _, err := store.Configure(workspaceOne, CursorAdapterKey, "subscription", "", ""); err != nil {
		t.Fatal(err)
	}
	if err := store.Remove(workspaceOne, CodexAdapterKey); err != nil {
		t.Fatal(err)
	}
	if _, ok := store.Get(workspaceOne, CodexAdapterKey); ok {
		t.Fatal("removed adapter remained configured")
	}
	if _, ok := store.Get(workspaceOne, CursorAdapterKey); !ok {
		t.Fatal("removing one adapter removed a distinct connection")
	}
}

func TestStorePersistsExactCursorModelOverride(t *testing.T) {
	path := filepath.Join(t.TempDir(), "providers")
	store, err := OpenStore(path, testSecret)
	if err != nil {
		t.Fatal(err)
	}
	const model = "gpt-5.5-medium"
	if _, err := store.Configure(workspaceOne, CursorAdapterKey, "subscription", model, ""); err != nil {
		t.Fatal(err)
	}
	reopened, err := OpenStore(path, testSecret)
	if err != nil {
		t.Fatal(err)
	}
	connection, ok := reopened.Get(workspaceOne, CursorAdapterKey)
	if !ok || connection.Model != model {
		t.Fatalf("Cursor model override was not persisted exactly: %#v", connection)
	}
}

func TestStoreRejectsWrongVaultSecret(t *testing.T) {
	path := filepath.Join(t.TempDir(), "providers")
	store, _ := OpenStore(path, testSecret)
	if _, err := store.Configure(workspaceOne, CodexAdapterKey, "api_key", "", "sk-secret-value"); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenStore(path, []byte("different-provider-secret-that-is-at-least-32-bytes")); err == nil {
		t.Fatal("encrypted provider state opened with a different vault secret")
	}
}

func TestOpenStoreScrubsLegacyRequestConnectionCopies(t *testing.T) {
	path := filepath.Join(t.TempDir(), "providers")
	store, err := OpenStore(path, testSecret)
	if err != nil {
		t.Fatal(err)
	}
	apiKey := "sk-legacy-request-copy"
	requestID := "63fc54ca-28cc-4b6d-a8b5-45cc055af90b"
	digest := strings.Repeat("f", 64)
	plaintext, err := json.Marshal(map[string]any{
		"version": stateVersion,
		"workspaces": map[string]any{
			workspaceOne: map[string]any{
				CodexAdapterKey: Connection{AuthMode: "api_key", Model: "gpt-5", APIKey: apiKey},
			},
		},
		"requests": map[string]any{
			requestID: map[string]any{
				"digest": digest, "workspace_key": workspaceOne, "adapter_key": CodexAdapterKey,
				"operation": "configure", "connection": Connection{AuthMode: "api_key", Model: "gpt-5", APIKey: apiKey},
			},
			"13fc54ca-28cc-4b6d-a8b5-45cc055af90b": map[string]any{
				"digest": strings.Repeat("e", 64), "workspace_key": workspaceOne, "adapter_key": CodexAdapterKey,
				"operation": "configure", "connection": Connection{AuthMode: "api_key", Model: "gpt-4", APIKey: apiKey},
			},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	encrypted, err := store.encrypt(plaintext)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, encrypted, 0o600); err != nil {
		t.Fatal(err)
	}
	reopened, err := OpenStore(path, testSecret)
	if err != nil {
		t.Fatal(err)
	}
	rewritten, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	rewrittenPlaintext, err := reopened.decrypt(rewritten)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Count(rewrittenPlaintext, []byte(apiKey)) != 1 || bytes.Contains(rewrittenPlaintext, []byte(`"connection"`)) {
		t.Fatalf("legacy request connection was not scrubbed: %s", rewrittenPlaintext)
	}
	if len(reopened.requests) != 1 {
		t.Fatalf("legacy request history was not compacted: %#v", reopened.requests)
	}
	if _, replay, err := reopened.ConfigureRequest(requestID, digest, workspaceOne, CodexAdapterKey, "api_key", "gpt-5", apiKey); err != nil || !replay {
		t.Fatalf("scrubbed request record did not preserve replay metadata: replay=%v err=%v", replay, err)
	}
}

func TestFailedAtomicUpdateRollsBackMemoryAndLeavesPriorStateReadable(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "providers")
	store, _ := OpenStore(path, testSecret)
	if _, err := store.Configure(workspaceOne, CodexAdapterKey, "api_key", "gpt-stable", "sk-stable-value"); err != nil {
		t.Fatal(err)
	}
	store.path = directory
	if _, err := store.Configure(workspaceOne, ClaudeAdapterKey, "api_key", "sonnet", "sk-new-value"); err == nil {
		t.Fatal("expected atomic replacement failure")
	}
	if _, ok := store.Get(workspaceOne, ClaudeAdapterKey); ok {
		t.Fatal("failed update remained visible in memory")
	}
	reopened, err := OpenStore(path, testSecret)
	if err != nil {
		t.Fatal(err)
	}
	stable, ok := reopened.Get(workspaceOne, CodexAdapterKey)
	if !ok || stable.Model != "gpt-stable" || stable.APIKey != "sk-stable-value" {
		t.Fatalf("failed update changed the prior durable state: %#v", stable)
	}
}

func TestConfigureRequestStoresSecretOnlyInTheActiveConnection(t *testing.T) {
	path := filepath.Join(t.TempDir(), "providers")
	store, err := OpenStore(path, testSecret)
	if err != nil {
		t.Fatal(err)
	}
	apiKey := "sk-request-record-must-not-retain-this"
	requestID := "eea34a0f-0d05-4b83-a0c9-cd7eb7686d15"
	digest := strings.Repeat("a", 64)
	if _, replay, err := store.ConfigureRequest(requestID, digest, workspaceOne, CodexAdapterKey, "api_key", "gpt-5", apiKey); err != nil || replay {
		t.Fatalf("configure request replay=%v err=%v", replay, err)
	}
	if record := store.requests[requestID]; record.Digest != digest || record.Operation != "configure" {
		t.Fatalf("unexpected request record: %#v", record)
	}
	encrypted, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	plaintext, err := store.decrypt(encrypted)
	if err != nil {
		t.Fatal(err)
	}
	if count := bytes.Count(plaintext, []byte(apiKey)); count != 1 {
		t.Fatalf("API key appears %d times in decrypted state; want active connection only: %s", count, plaintext)
	}
	if bytes.Contains(plaintext, []byte(`"connection"`)) {
		t.Fatalf("request history retained a connection snapshot: %s", plaintext)
	}
}

func TestRequestHistoryKeepsOnlyLatestMutationPerWorkspaceAndAdapter(t *testing.T) {
	store, err := OpenStore("", testSecret)
	if err != nil {
		t.Fatal(err)
	}
	for index := 1; index <= 100; index++ {
		requestID := fmt.Sprintf("00000000-0000-4000-8000-%012x", index)
		digest := fmt.Sprintf("%064x", index)
		if _, _, err := store.ConfigureRequest(requestID, digest, workspaceOne, CodexAdapterKey, "api_key", fmt.Sprintf("gpt-%d", index), "sk-bounded-history-value"); err != nil {
			t.Fatal(err)
		}
		if len(store.requests) != 1 {
			t.Fatalf("request history length = %d after mutation %d; want 1", len(store.requests), index)
		}
	}
	if _, _, err := store.ConfigureRequest("00000000-0000-4000-8000-000000000101", strings.Repeat("b", 64), workspaceOne, ClaudeAdapterKey, "api_key", "sonnet", "sk-second-adapter-value"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.ConfigureRequest("00000000-0000-4000-8000-000000000102", strings.Repeat("c", 64), workspaceTwo, CodexAdapterKey, "api_key", "gpt-other", "sk-other-workspace-value"); err != nil {
		t.Fatal(err)
	}
	if len(store.requests) != 3 {
		t.Fatalf("request history length = %d; want one record for each workspace/provider scope", len(store.requests))
	}
}

func TestRemoveRequestPurgesConnectionSecretAndPriorReplayRecords(t *testing.T) {
	path := filepath.Join(t.TempDir(), "providers")
	store, err := OpenStore(path, testSecret)
	if err != nil {
		t.Fatal(err)
	}
	apiKey := "sk-remove-must-erase-value"
	configureID := "9434f3c6-4a99-40b1-8568-4cad9504920d"
	removeID := "e11a1918-9194-4932-ae33-458c431d5536"
	if _, _, err := store.ConfigureRequest(configureID, strings.Repeat("d", 64), workspaceOne, CodexAdapterKey, "api_key", "gpt-5", apiKey); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RemoveRequest(removeID, strings.Repeat("e", 64), workspaceOne, CodexAdapterKey); err != nil {
		t.Fatal(err)
	}
	if _, configured := store.Get(workspaceOne, CodexAdapterKey); configured {
		t.Fatal("removed provider connection remained configured")
	}
	if len(store.requests) != 1 || store.requests[removeID].Operation != "remove" {
		t.Fatalf("remove did not replace prior replay history: %#v", store.requests)
	}
	if _, exists := store.requests[configureID]; exists {
		t.Fatal("configure replay record survived provider removal")
	}
	encrypted, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	plaintext, err := store.decrypt(encrypted)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(plaintext, []byte(apiKey)) {
		t.Fatalf("removed API key remained in provider state: %s", plaintext)
	}
}

func TestPurgeWorkspaceRemovesOnlyTargetCredentialsAndRequestHistory(t *testing.T) {
	path := filepath.Join(t.TempDir(), "providers")
	store, err := OpenStore(path, testSecret)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.ConfigureRequest("44dcdf14-6995-4f64-998f-c2b614bcbaf0", strings.Repeat("1", 64), workspaceOne, CodexAdapterKey, "api_key", "gpt-5", "sk-workspace-one-codex"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.ConfigureRequest("13c1026b-72f8-410e-ab67-a4fa0231ef90", strings.Repeat("2", 64), workspaceOne, ClaudeAdapterKey, "api_key", "sonnet", "sk-workspace-one-claude"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.ConfigureRequest("13d11d49-af69-4e5a-a076-1a1bb0c4425b", strings.Repeat("3", 64), workspaceTwo, CodexAdapterKey, "api_key", "gpt-5", "sk-workspace-two"); err != nil {
		t.Fatal(err)
	}
	if err := store.PurgeWorkspaceRequest("26937086-5b67-4cc0-9949-ffda802715a3", strings.Repeat("4", 64), workspaceOne); err != nil {
		t.Fatal(err)
	}
	if connections := store.List(workspaceOne); len(connections) != 0 {
		t.Fatalf("purged workspace retained connections: %#v", connections)
	}
	for _, record := range store.requests {
		if record.WorkspaceKey == workspaceOne {
			t.Fatalf("purged workspace retained request record: %#v", record)
		}
	}
	remaining, configured := store.Get(workspaceTwo, CodexAdapterKey)
	if !configured || remaining.APIKey != "sk-workspace-two" {
		t.Fatalf("cross-workspace purge changed another workspace: %#v", remaining)
	}
	reopened, err := OpenStore(path, testSecret)
	if err != nil {
		t.Fatal(err)
	}
	if len(reopened.List(workspaceOne)) != 0 {
		t.Fatal("purged workspace returned after reopening state")
	}
	if _, configured := reopened.Get(workspaceTwo, CodexAdapterKey); !configured {
		t.Fatal("unrelated workspace was lost after reopening state")
	}
}
