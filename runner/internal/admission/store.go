package admission

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

const (
	maximumRecords = 100_000
	maximumBytes   = 64 * 1024 * 1024
)

var (
	ErrConflict          = errors.New("idempotency key already has a different request")
	ErrCapacity          = errors.New("runner admission store reached its capacity")
	errDurabilityUnknown = errors.New("admission state durability is unknown")
)

type Record struct {
	RequestDigest string                     `json:"request_digest"`
	Response      protocol.AdmissionResponse `json:"response"`
}

type Store struct {
	mu      sync.Mutex
	path    string
	records map[string]Record
}

func OpenStore(path string) (*Store, error) {
	store := &Store{path: path, records: make(map[string]Record)}
	if path == "" {
		return store, nil
	}
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return store, nil
	}
	if err != nil {
		return nil, fmt.Errorf("inspect admission store: %w", err)
	}
	if info.Size() > maximumBytes {
		return nil, fmt.Errorf("admission store exceeds %d bytes", maximumBytes)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read admission store: %w", err)
	}
	if err := json.Unmarshal(data, &store.records); err != nil {
		return nil, fmt.Errorf("decode admission store: %w", err)
	}
	if len(store.records) > maximumRecords {
		return nil, ErrCapacity
	}
	return store, nil
}

func (store *Store) Admit(key, digest string, response protocol.AdmissionResponse) (protocol.AdmissionResponse, bool, error) {
	store.mu.Lock()
	defer store.mu.Unlock()

	if record, exists := store.records[key]; exists {
		if record.RequestDigest != digest {
			return protocol.AdmissionResponse{}, false, ErrConflict
		}
		return record.Response, true, nil
	}
	if len(store.records) >= maximumRecords {
		return protocol.AdmissionResponse{}, false, ErrCapacity
	}
	store.records[key] = Record{RequestDigest: digest, Response: response}
	if err := store.persist(); err != nil {
		if !errors.Is(err, errDurabilityUnknown) {
			delete(store.records, key)
		}
		return protocol.AdmissionResponse{}, false, err
	}
	return response, false, nil
}

func (store *Store) persist() error {
	if store.path == "" {
		return nil
	}
	data, err := json.Marshal(store.records)
	if err != nil {
		return fmt.Errorf("encode admission store: %w", err)
	}
	if len(data) > maximumBytes {
		return ErrCapacity
	}
	directory := filepath.Dir(store.path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("create admission store directory: %w", err)
	}
	temporary, err := os.CreateTemp(directory, ".admissions-*")
	if err != nil {
		return fmt.Errorf("create temporary admission store: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return fmt.Errorf("protect admission store: %w", err)
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return fmt.Errorf("write admission store: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return fmt.Errorf("sync admission store: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close admission store: %w", err)
	}
	if err := os.Rename(temporaryPath, store.path); err != nil {
		return fmt.Errorf("replace admission store: %w", err)
	}
	directoryHandle, err := os.Open(directory)
	if err != nil {
		return fmt.Errorf("%w: open admission store directory: %v", errDurabilityUnknown, err)
	}
	defer directoryHandle.Close()
	if err := directoryHandle.Sync(); err != nil {
		return fmt.Errorf("%w: sync admission store directory: %v", errDurabilityUnknown, err)
	}
	return nil
}
