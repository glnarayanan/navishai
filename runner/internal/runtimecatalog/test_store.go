package runtimecatalog

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

const (
	maximumTestStoreBytes   = 16 * 1024 * 1024
	maximumTestStoreRecords = 10_000
)

var (
	ErrTestConflict      = errors.New("runtime test request id already has a different request")
	ErrTestCapacity      = errors.New("runtime test store reached its capacity")
	ErrInvalidTestResult = errors.New("invalid runtime test result")
)

type testStoreRecord struct {
	RequestDigest            string     `json:"request_digest"`
	ConfigurationFingerprint string     `json:"configuration_fingerprint"`
	Result                   TestResult `json:"result"`
}

type TestStore struct {
	mu       sync.Mutex
	path     string
	records  map[string]testStoreRecord
	inFlight map[string]*testStoreFlight
}

type testStoreFlight struct {
	requestDigest            string
	configurationFingerprint string
	executionMode            string
	done                     chan struct{}
	result                   TestResult
	err                      error
}

func OpenTestStore(path string) (*TestStore, error) {
	store := &TestStore{
		path: path, records: make(map[string]testStoreRecord), inFlight: make(map[string]*testStoreFlight),
	}
	if path == "" {
		return store, nil
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return store, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read runtime test store: %w", err)
	}
	if len(data) > maximumTestStoreBytes || json.Unmarshal(data, &store.records) != nil || len(store.records) > maximumTestStoreRecords {
		return nil, ErrTestCapacity
	}
	if store.records == nil {
		store.records = make(map[string]testStoreRecord)
	}
	for requestID, record := range store.records {
		if !workspaceKeyPattern.MatchString(requestID) || !configurationIdentityPattern.MatchString(record.RequestDigest) ||
			!validTestResult(record.Result, record.Result.ExecutionMode, record.ConfigurationFingerprint) {
			return nil, errors.New("runtime test store contains an invalid record")
		}
	}
	return store, nil
}

func (store *TestStore) Resolve(ctx context.Context, request TestRequest, digest string, run func() (TestResult, error)) (TestResult, bool, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	store.mu.Lock()
	if store.records == nil {
		store.records = make(map[string]testStoreRecord)
	}
	if store.inFlight == nil {
		store.inFlight = make(map[string]*testStoreFlight)
	}
	for {
		if record, exists := store.records[request.RequestID]; exists {
			if record.RequestDigest != digest || record.ConfigurationFingerprint != request.ConfigurationFingerprint ||
				record.Result.ExecutionMode != request.ExecutionMode {
				store.mu.Unlock()
				return TestResult{}, false, ErrTestConflict
			}
			store.mu.Unlock()
			return record.Result, true, nil
		}
		if flight, exists := store.inFlight[request.RequestID]; exists {
			if flight.requestDigest != digest || flight.configurationFingerprint != request.ConfigurationFingerprint ||
				flight.executionMode != request.ExecutionMode {
				store.mu.Unlock()
				return TestResult{}, false, ErrTestConflict
			}
			done := flight.done
			store.mu.Unlock()
			select {
			case <-done:
				return flight.result, flight.err == nil, flight.err
			case <-ctx.Done():
				return TestResult{}, false, ctx.Err()
			}
		}
		if len(store.records)+len(store.inFlight) >= maximumTestStoreRecords {
			store.mu.Unlock()
			return TestResult{}, false, ErrTestCapacity
		}
		flight := &testStoreFlight{
			requestDigest: digest, configurationFingerprint: request.ConfigurationFingerprint,
			executionMode: request.ExecutionMode, done: make(chan struct{}),
		}
		store.inFlight[request.RequestID] = flight
		store.mu.Unlock()

		result, err := run()
		if err == nil && !validTestResult(result, request.ExecutionMode, request.ConfigurationFingerprint) {
			err = ErrInvalidTestResult
		}

		store.mu.Lock()
		delete(store.inFlight, request.RequestID)
		if err == nil {
			store.records[request.RequestID] = testStoreRecord{
				RequestDigest: digest, ConfigurationFingerprint: request.ConfigurationFingerprint, Result: result,
			}
			if persistErr := store.persist(); persistErr != nil {
				delete(store.records, request.RequestID)
				err = persistErr
			}
		}
		flight.result, flight.err = result, err
		close(flight.done)
		store.mu.Unlock()
		return result, false, err
	}
}

func (store *TestStore) persist() error {
	if store.path == "" {
		return nil
	}
	data, err := json.Marshal(store.records)
	if err != nil || len(data) > maximumTestStoreBytes {
		return ErrTestCapacity
	}
	directory := filepath.Dir(store.path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(directory, ".runtime-tests-*")
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
