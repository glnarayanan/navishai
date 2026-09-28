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
	// Keep provider pressure bounded while allowing unrelated cached replays to proceed.
	maximumConcurrentSearches = 4
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

type inFlightSearch struct {
	digest   string
	done     chan struct{}
	response Response
	err      error
}

type Store struct {
	mu        sync.Mutex
	persistMu sync.Mutex
	path      string
	records   map[string]storeRecord
	inFlight  map[string]*inFlightSearch
	searches  chan struct{}
}

func OpenStore(path string) (*Store, error) {
	store := &Store{
		path: path, records: make(map[string]storeRecord), inFlight: make(map[string]*inFlightSearch),
		searches: make(chan struct{}, maximumConcurrentSearches),
	}
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
	if record, exists := store.records[key]; exists {
		if record.RequestDigest != digest {
			store.mu.Unlock()
			return Response{}, false, ErrConflict
		}
		store.mu.Unlock()
		return record.Response, true, nil
	}
	if pending, exists := store.inFlight[key]; exists {
		if pending.digest != digest {
			store.mu.Unlock()
			return Response{}, false, ErrConflict
		}
		store.mu.Unlock()
		<-pending.done
		return pending.response, pending.err == nil, pending.err
	}
	// Reservations prevent provider work that could never fit in the record store.
	if len(store.records)+len(store.inFlight) >= maximumStoreRecords {
		store.mu.Unlock()
		return Response{}, false, ErrCapacity
	}
	pending := &inFlightSearch{digest: digest, done: make(chan struct{})}
	store.inFlight[key] = pending
	store.mu.Unlock()

	store.searches <- struct{}{}
	// Bound completed responses waiting for persistence as well as provider calls.
	defer func() { <-store.searches }()
	response, err := search()
	if err == nil && (response.RequestKey != key || response.Validate(protocol.Version) != nil) {
		err = ErrInvalidRequest
	}
	if err == nil {
		err = store.commit(key, digest, response)
	}
	if err != nil {
		response = Response{}
	}

	store.mu.Lock()
	pending.response = response
	pending.err = err
	delete(store.inFlight, key)
	close(pending.done)
	store.mu.Unlock()
	if err != nil {
		return Response{}, false, err
	}
	return response, false, nil
}

func (store *Store) commit(key, digest string, response Response) error {
	store.persistMu.Lock()
	defer store.persistMu.Unlock()

	store.mu.Lock()
	records := make(map[string]storeRecord, len(store.records)+1)
	for storedKey, record := range store.records {
		records[storedKey] = record
	}
	records[key] = storeRecord{RequestDigest: digest, Response: response}
	store.mu.Unlock()

	if err := store.persist(records); err != nil {
		return err
	}
	store.mu.Lock()
	store.records[key] = records[key]
	delete(store.inFlight, key)
	store.mu.Unlock()
	return nil
}

func (store *Store) persist(records map[string]storeRecord) error {
	if store.path == "" {
		return nil
	}
	data, err := json.Marshal(records)
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
