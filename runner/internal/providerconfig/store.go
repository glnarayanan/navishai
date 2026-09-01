package providerconfig

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

const (
	stateVersion      = "v1"
	maximumStateBytes = 16 * 1024 * 1024
	maximumWorkspaces = 10_000
	maximumRequests   = maximumWorkspaces * 4
	maximumKeyBytes   = 16 * 1024
	keyDerivationInfo = "navishai-runner-provider-state-v1"
)

var (
	ErrInvalidConnection = errors.New("invalid provider connection")
	ErrStateCapacity     = errors.New("provider state reached its capacity")
	ErrStateUnreadable   = errors.New("provider state is unreadable")
	ErrRequestConflict   = errors.New("provider request id already has different input")
)

type Connection struct {
	AuthMode      string `json:"auth_mode"`
	ExecutionMode string `json:"execution_mode"`
	Model         string `json:"model"`
	APIKey        string `json:"api_key"`
}

type state struct {
	Version    string                           `json:"version"`
	Workspaces map[string]map[string]Connection `json:"workspaces"`
	Requests   map[string]requestRecord         `json:"requests"`
}

type requestRecord struct {
	Digest       string `json:"digest"`
	WorkspaceKey string `json:"workspace_key"`
	AdapterKey   string `json:"adapter_key"`
	Operation    string `json:"operation"`
}

type envelope struct {
	Version    string `json:"version"`
	Nonce      string `json:"nonce"`
	Ciphertext string `json:"ciphertext"`
}

type Store struct {
	mu         sync.RWMutex
	path       string
	key        [32]byte
	workspaces map[string]map[string]Connection
	requests   map[string]requestRecord
}

func OpenStore(path string, secret []byte) (*Store, error) {
	if len(secret) < 32 {
		return nil, ErrStateUnreadable
	}
	store := &Store{path: path, key: deriveKey(secret), workspaces: make(map[string]map[string]Connection), requests: make(map[string]requestRecord)}
	if path == "" {
		return store, nil
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return store, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read provider state: %w", err)
	}
	if len(data) > maximumStateBytes {
		return nil, ErrStateCapacity
	}
	plaintext, err := store.decrypt(data)
	if err != nil {
		return nil, ErrStateUnreadable
	}
	var decoded state
	var raw struct {
		Workspaces map[string]map[string]json.RawMessage `json:"workspaces"`
	}
	if json.Unmarshal(plaintext, &decoded) != nil || json.Unmarshal(plaintext, &raw) != nil ||
		decoded.Version != stateVersion || decoded.Workspaces == nil ||
		len(decoded.Workspaces) > maximumWorkspaces {
		return nil, ErrStateUnreadable
	}
	migrated := false
	for workspaceKey, connections := range decoded.Workspaces {
		if !validUUID(workspaceKey) || len(connections) > len(definitions) {
			return nil, ErrStateUnreadable
		}
		for adapterKey, connection := range connections {
			rawConnection, ok := raw.Workspaces[workspaceKey][adapterKey]
			if !ok {
				return nil, ErrStateUnreadable
			}
			var fields map[string]json.RawMessage
			if json.Unmarshal(rawConnection, &fields) != nil {
				return nil, ErrStateUnreadable
			}
			if _, present := fields["execution_mode"]; !present {
				switch connection.AuthMode {
				case "api_key":
					connection.ExecutionMode = protocol.ExecutionModeBounded
				case "subscription":
					connection.ExecutionMode = protocol.ExecutionModeLegacyUnknown
				default:
					return nil, ErrStateUnreadable
				}
				decoded.Workspaces[workspaceKey][adapterKey] = connection
				migrated = true
			}
			if validateStoredConnection(adapterKey, connection) != nil {
				return nil, ErrStateUnreadable
			}
		}
	}
	if decoded.Requests == nil {
		decoded.Requests = make(map[string]requestRecord)
	}
	for requestID, record := range decoded.Requests {
		if !validUUID(requestID) || !validUUID(record.WorkspaceKey) || !digestPattern.MatchString(record.Digest) ||
			definitions[record.AdapterKey].AdapterKey == "" || (record.Operation != "configure" && record.Operation != "remove") {
			return nil, ErrStateUnreadable
		}
	}
	var compacted bool
	decoded.Requests, compacted = compactRequestHistory(decoded.Requests)
	if len(decoded.Requests) > maximumRequests || distinctWorkspaceCount(decoded.Workspaces, decoded.Requests) > maximumWorkspaces {
		return nil, ErrStateCapacity
	}
	store.workspaces = decoded.Workspaces
	store.requests = decoded.Requests
	if migrated || compacted || legacyRequestConnectionsPresent(plaintext) {
		if err := store.persist(); err != nil {
			return nil, fmt.Errorf("rewrite provider state: %w", err)
		}
	}
	return store, nil
}

func (store *Store) Get(workspaceKey, adapterKey string) (Connection, bool) {
	store.mu.RLock()
	defer store.mu.RUnlock()
	connection, ok := store.workspaces[workspaceKey][adapterKey]
	return connection, ok
}

func (store *Store) List(workspaceKey string) map[string]Connection {
	store.mu.RLock()
	defer store.mu.RUnlock()
	result := make(map[string]Connection, len(store.workspaces[workspaceKey]))
	for adapterKey, connection := range store.workspaces[workspaceKey] {
		result[adapterKey] = connection
	}
	return result
}

func (store *Store) Configure(workspaceKey, adapterKey, authMode, executionMode, model, apiKey string) (Connection, error) {
	store.mu.Lock()
	defer store.mu.Unlock()
	if !validUUID(workspaceKey) {
		return Connection{}, ErrInvalidConnection
	}
	current, exists := store.workspaces[workspaceKey][adapterKey]
	if authMode == "api_key" && apiKey == "" {
		if !exists || current.AuthMode != authMode || current.APIKey == "" {
			return Connection{}, ErrInvalidConnection
		}
		apiKey = current.APIKey
	}
	connection := Connection{AuthMode: authMode, ExecutionMode: executionMode, Model: model, APIKey: apiKey}
	if err := validateConnection(adapterKey, connection, true); err != nil {
		return Connection{}, err
	}
	if !store.workspaceSlotAvailable(workspaceKey) {
		return Connection{}, ErrStateCapacity
	}
	previous := cloneConnections(store.workspaces[workspaceKey])
	previousRequests := cloneRequests(store.requests)
	if store.workspaces[workspaceKey] == nil {
		store.workspaces[workspaceKey] = make(map[string]Connection)
	}
	store.workspaces[workspaceKey][adapterKey] = connection
	store.pruneRequests(workspaceKey, adapterKey)
	if err := store.persist(); err != nil {
		store.requests = previousRequests
		if previous == nil {
			delete(store.workspaces, workspaceKey)
		} else {
			store.workspaces[workspaceKey] = previous
		}
		return Connection{}, err
	}
	return connection, nil
}

func (store *Store) ConfigureRequest(requestID, digest, workspaceKey, adapterKey, authMode, executionMode, model, apiKey string) (Connection, bool, error) {
	store.mu.Lock()
	defer store.mu.Unlock()
	if replay, ok, err := store.resolveRequest(requestID, digest, workspaceKey, adapterKey, "configure"); ok || err != nil {
		connection, _ := store.workspaces[replay.WorkspaceKey][replay.AdapterKey]
		return connection, ok, err
	}
	if !validUUID(workspaceKey) {
		return Connection{}, false, ErrInvalidConnection
	}
	current, exists := store.workspaces[workspaceKey][adapterKey]
	if authMode == "api_key" && apiKey == "" {
		if !exists || current.AuthMode != authMode || current.APIKey == "" {
			return Connection{}, false, ErrInvalidConnection
		}
		apiKey = current.APIKey
	}
	connection := Connection{AuthMode: authMode, ExecutionMode: executionMode, Model: model, APIKey: apiKey}
	if validateConnection(adapterKey, connection, true) != nil {
		return Connection{}, false, ErrInvalidConnection
	}
	if !store.workspaceSlotAvailable(workspaceKey) {
		return Connection{}, false, ErrStateCapacity
	}
	previous := cloneConnections(store.workspaces[workspaceKey])
	previousRequests := cloneRequests(store.requests)
	if store.workspaces[workspaceKey] == nil {
		store.workspaces[workspaceKey] = make(map[string]Connection)
	}
	store.workspaces[workspaceKey][adapterKey] = connection
	store.pruneRequests(workspaceKey, adapterKey)
	store.requests[requestID] = requestRecord{Digest: digest, WorkspaceKey: workspaceKey, AdapterKey: adapterKey, Operation: "configure"}
	if err := store.persist(); err != nil {
		store.requests = previousRequests
		if previous == nil {
			delete(store.workspaces, workspaceKey)
		} else {
			store.workspaces[workspaceKey] = previous
		}
		return Connection{}, false, err
	}
	return connection, false, nil
}

func (store *Store) Remove(workspaceKey, adapterKey string) error {
	store.mu.Lock()
	defer store.mu.Unlock()
	if !validUUID(workspaceKey) || definitions[adapterKey].AdapterKey == "" {
		return ErrInvalidConnection
	}
	previous := cloneConnections(store.workspaces[workspaceKey])
	previousRequests := cloneRequests(store.requests)
	delete(store.workspaces[workspaceKey], adapterKey)
	if len(store.workspaces[workspaceKey]) == 0 {
		delete(store.workspaces, workspaceKey)
	}
	store.pruneRequests(workspaceKey, adapterKey)
	if err := store.persist(); err != nil {
		store.requests = previousRequests
		if previous == nil {
			delete(store.workspaces, workspaceKey)
		} else {
			store.workspaces[workspaceKey] = previous
		}
		return err
	}
	return nil
}

func (store *Store) RemoveRequest(requestID, digest, workspaceKey, adapterKey string) (bool, error) {
	store.mu.Lock()
	defer store.mu.Unlock()
	if _, ok, err := store.resolveRequest(requestID, digest, workspaceKey, adapterKey, "remove"); ok || err != nil {
		return ok, err
	}
	if !validUUID(workspaceKey) || definitions[adapterKey].AdapterKey == "" {
		return false, ErrInvalidConnection
	}
	if !store.workspaceSlotAvailable(workspaceKey) {
		return false, ErrStateCapacity
	}
	previous := cloneConnections(store.workspaces[workspaceKey])
	previousRequests := cloneRequests(store.requests)
	delete(store.workspaces[workspaceKey], adapterKey)
	if len(store.workspaces[workspaceKey]) == 0 {
		delete(store.workspaces, workspaceKey)
	}
	store.pruneRequests(workspaceKey, adapterKey)
	store.requests[requestID] = requestRecord{Digest: digest, WorkspaceKey: workspaceKey, AdapterKey: adapterKey, Operation: "remove"}
	if err := store.persist(); err != nil {
		store.requests = previousRequests
		if previous == nil {
			delete(store.workspaces, workspaceKey)
		} else {
			store.workspaces[workspaceKey] = previous
		}
		return false, err
	}
	return false, nil
}

func (store *Store) PurgeWorkspaceRequest(requestID, digest, workspaceKey string) error {
	if !validUUID(requestID) || !digestPattern.MatchString(digest) || !validUUID(workspaceKey) {
		return ErrInvalidConnection
	}
	return store.PurgeWorkspace(workspaceKey)
}

func (store *Store) PurgeWorkspace(workspaceKey string) error {
	store.mu.Lock()
	defer store.mu.Unlock()
	if !validUUID(workspaceKey) {
		return ErrInvalidConnection
	}
	previous := cloneConnections(store.workspaces[workspaceKey])
	previousRequests := cloneRequests(store.requests)
	delete(store.workspaces, workspaceKey)
	store.pruneWorkspaceRequests(workspaceKey)
	if err := store.persist(); err != nil {
		store.requests = previousRequests
		if previous != nil {
			store.workspaces[workspaceKey] = previous
		}
		return err
	}
	return nil
}

func (store *Store) resolveRequest(requestID, digest, workspaceKey, adapterKey, operation string) (requestRecord, bool, error) {
	if !validUUID(requestID) || !digestPattern.MatchString(digest) {
		return requestRecord{}, false, ErrInvalidConnection
	}
	record, exists := store.requests[requestID]
	if !exists {
		return requestRecord{}, false, nil
	}
	if record.Digest != digest || record.WorkspaceKey != workspaceKey || record.AdapterKey != adapterKey || record.Operation != operation {
		return requestRecord{}, false, ErrRequestConflict
	}
	return record, true, nil
}

func (store *Store) pruneRequests(workspaceKey, adapterKey string) {
	for requestID, record := range store.requests {
		if record.WorkspaceKey == workspaceKey && record.AdapterKey == adapterKey {
			delete(store.requests, requestID)
		}
	}
}

func (store *Store) pruneWorkspaceRequests(workspaceKey string) {
	for requestID, record := range store.requests {
		if record.WorkspaceKey == workspaceKey {
			delete(store.requests, requestID)
		}
	}
}

func (store *Store) workspaceSlotAvailable(workspaceKey string) bool {
	if store.workspaces[workspaceKey] != nil {
		return true
	}
	for _, record := range store.requests {
		if record.WorkspaceKey == workspaceKey {
			return true
		}
	}
	return distinctWorkspaceCount(store.workspaces, store.requests) < maximumWorkspaces
}

func compactRequestHistory(requests map[string]requestRecord) (map[string]requestRecord, bool) {
	result := make(map[string]requestRecord, len(requests))
	requestByScope := make(map[string]string, len(requests))
	compacted := false
	for requestID, record := range requests {
		scope := record.WorkspaceKey + "\x00" + record.AdapterKey
		if previousID, exists := requestByScope[scope]; exists {
			compacted = true
			if previousID > requestID {
				continue
			}
			delete(result, previousID)
		}
		requestByScope[scope] = requestID
		result[requestID] = record
	}
	return result, compacted
}

func legacyRequestConnectionsPresent(plaintext []byte) bool {
	var encoded struct {
		Requests map[string]json.RawMessage `json:"requests"`
	}
	if json.Unmarshal(plaintext, &encoded) != nil {
		return false
	}
	for _, rawRecord := range encoded.Requests {
		var fields map[string]json.RawMessage
		if json.Unmarshal(rawRecord, &fields) == nil {
			if _, exists := fields["connection"]; exists {
				return true
			}
		}
	}
	return false
}

func distinctWorkspaceCount(workspaces map[string]map[string]Connection, requests map[string]requestRecord) int {
	distinct := make(map[string]struct{}, len(workspaces))
	for workspaceKey := range workspaces {
		distinct[workspaceKey] = struct{}{}
	}
	for _, record := range requests {
		distinct[record.WorkspaceKey] = struct{}{}
	}
	return len(distinct)
}

func validateConnection(adapterKey string, connection Connection, requireInput bool) error {
	if err := validateStoredConnection(adapterKey, connection); err != nil ||
		connection.ExecutionMode == protocol.ExecutionModeLegacyUnknown {
		return ErrInvalidConnection
	}
	if connection.AuthMode == "api_key" && connection.ExecutionMode != protocol.ExecutionModeBounded {
		return ErrInvalidConnection
	}
	if connection.AuthMode == "subscription" &&
		(connection.ExecutionMode != protocol.ExecutionModeHostTrusted && connection.ExecutionMode != protocol.ExecutionModeStrongIsolated) {
		return ErrInvalidConnection
	}
	if _, ok := definitions[adapterKey]; !ok {
		return ErrInvalidConnection
	}
	if requireInput && connection.AuthMode == "api_key" && len(connection.APIKey) < 8 {
		return ErrInvalidConnection
	}
	return nil
}

func validateStoredConnection(adapterKey string, connection Connection) error {
	definition, ok := definitions[adapterKey]
	if !ok || !contains(definition.AuthModes, connection.AuthMode) || len(connection.Model) > 200 ||
		containsControl(connection.Model) || len(connection.APIKey) > maximumKeyBytes || containsNUL(connection.APIKey) {
		return ErrInvalidConnection
	}
	if connection.AuthMode == "api_key" {
		if connection.APIKey == "" || connection.ExecutionMode != protocol.ExecutionModeBounded {
			return ErrInvalidConnection
		}
	} else if connection.APIKey != "" ||
		(connection.ExecutionMode != protocol.ExecutionModeLegacyUnknown &&
			connection.ExecutionMode != protocol.ExecutionModeHostTrusted &&
			connection.ExecutionMode != protocol.ExecutionModeStrongIsolated) {
		return ErrInvalidConnection
	}
	return nil
}

func (store *Store) persist() error {
	if store.path == "" {
		return nil
	}
	plaintext, err := json.Marshal(state{Version: stateVersion, Workspaces: store.workspaces, Requests: store.requests})
	if err != nil || len(plaintext) > maximumStateBytes {
		return ErrStateCapacity
	}
	data, err := store.encrypt(plaintext)
	if err != nil || len(data) > maximumStateBytes {
		return ErrStateCapacity
	}
	directory := filepath.Dir(store.path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(directory, ".providers-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, store.path); err != nil {
		return err
	}
	if err := os.Chmod(store.path, 0o600); err != nil {
		return err
	}
	directoryHandle, err := os.Open(directory)
	if err != nil {
		return err
	}
	defer directoryHandle.Close()
	return directoryHandle.Sync()
}

func (store *Store) encrypt(plaintext []byte) ([]byte, error) {
	block, err := aes.NewCipher(store.key[:])
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}
	ciphertext := aead.Seal(nil, nonce, plaintext, []byte(keyDerivationInfo))
	return json.Marshal(envelope{Version: stateVersion, Nonce: base64.RawStdEncoding.EncodeToString(nonce), Ciphertext: base64.RawStdEncoding.EncodeToString(ciphertext)})
}

func (store *Store) decrypt(data []byte) ([]byte, error) {
	var encoded envelope
	if json.Unmarshal(data, &encoded) != nil || encoded.Version != stateVersion {
		return nil, ErrStateUnreadable
	}
	nonce, nonceErr := base64.RawStdEncoding.DecodeString(encoded.Nonce)
	ciphertext, cipherErr := base64.RawStdEncoding.DecodeString(encoded.Ciphertext)
	block, blockErr := aes.NewCipher(store.key[:])
	if nonceErr != nil || cipherErr != nil || blockErr != nil {
		return nil, ErrStateUnreadable
	}
	aead, err := cipher.NewGCM(block)
	if err != nil || len(nonce) != aead.NonceSize() {
		return nil, ErrStateUnreadable
	}
	return aead.Open(nil, nonce, ciphertext, []byte(keyDerivationInfo))
}

func deriveKey(secret []byte) [32]byte {
	salt := []byte("NavishAI runner provider state")
	extract := hmac.New(sha256.New, salt)
	_, _ = extract.Write(secret)
	prk := extract.Sum(nil)
	expand := hmac.New(sha256.New, prk)
	_, _ = expand.Write([]byte(keyDerivationInfo))
	_, _ = expand.Write([]byte{1})
	var result [32]byte
	copy(result[:], expand.Sum(nil))
	return result
}

func cloneConnections(values map[string]Connection) map[string]Connection {
	if values == nil {
		return nil
	}
	result := make(map[string]Connection, len(values))
	for key, value := range values {
		result[key] = value
	}
	return result
}

func cloneRequests(values map[string]requestRecord) map[string]requestRecord {
	result := make(map[string]requestRecord, len(values))
	for key, value := range values {
		result[key] = value
	}
	return result
}

func contains(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}

func containsControl(value string) bool {
	for _, character := range value {
		if character < 0x20 || character == 0x7f {
			return true
		}
	}
	return false
}

func containsNUL(value string) bool {
	for _, character := range value {
		if character == 0 {
			return true
		}
	}
	return false
}
