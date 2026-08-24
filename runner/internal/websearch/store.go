package websearch

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sync"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

const (
	maximumStoreBytes   = 64 * 1024 * 1024
	maximumStoreRecords = 100_000
)

var digestPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

var (
	ErrConflict = errors.New("web search request key already has a different request")
	ErrCapacity = errors.New("web search store reached its capacity")
)

type storeRecord struct {
	RequestDigest string   `json:"request_digest"`
	Response      Response `json:"response"`
}

type Store struct {
	mu      sync.Mutex
	path    string
	records map[string]storeRecord
}

func OpenStore(path string) (*Store, error) {
	store := &Store{path: path, records: make(map[string]storeRecord)}
	if path == "" {
		return store, nil
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return store, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read web search store: %w", err)
	}
	if len(data) > maximumStoreBytes {
		return nil, ErrCapacity
	}
	if err := json.Unmarshal(data, &store.records); err != nil {
		return nil, fmt.Errorf("decode web search store: %w", err)
	}
	if len(store.records) > maximumStoreRecords {
		return nil, ErrCapacity
	}
	for key, record := range store.records {
		if !keyPattern.MatchString(key) || !digestPattern.MatchString(record.RequestDigest) ||
			record.Response.RequestKey != key || record.Response.Validate(protocol.Version) != nil {
			return nil, errors.New("web search store contains an invalid record")
		}
	}
	return store, nil
}

func (store *Store) Resolve(key, digest string, search func() (Response, error)) (Response, bool, error) {
	store.mu.Lock()
	defer store.mu.Unlock()
	if record, exists := store.records[key]; exists {
		if record.RequestDigest != digest {
			return Response{}, false, ErrConflict
		}
		return record.Response, true, nil
	}
	if len(store.records) >= maximumStoreRecords {
		return Response{}, false, ErrCapacity
	}
	response, err := search()
	if err != nil {
		return Response{}, false, err
	}
	if response.RequestKey != key || response.Validate(protocol.Version) != nil {
		return Response{}, false, ErrInvalidRequest
	}
	store.records[key] = storeRecord{RequestDigest: digest, Response: response}
	if err := store.persist(); err != nil {
		delete(store.records, key)
		return Response{}, false, err
	}
	return response, false, nil
}

func (store *Store) persist() error {
	if store.path == "" {
		return nil
	}
	data, err := json.Marshal(store.records)
	if err != nil || len(data) > maximumStoreBytes {
		return ErrCapacity
	}
	directory := filepath.Dir(store.path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(directory, ".web-search-*")
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
	directoryHandle, err := os.Open(directory)
	if err != nil {
		return err
	}
	defer directoryHandle.Close()
	return directoryHandle.Sync()
}
