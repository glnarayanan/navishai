package runtimecatalog

import (
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
	mu      sync.Mutex
	path    string
	records map[string]testStoreRecord
}

func OpenTestStore(path string) (*TestStore, error) {
	store := &TestStore{path: path, records: make(map[string]testStoreRecord)}
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
	for requestID, record := range store.records {
		if !workspaceKeyPattern.MatchString(requestID) || !configurationIdentityPattern.MatchString(record.RequestDigest) ||
			!validTestResult(record.Result, record.Result.ExecutionMode, record.ConfigurationFingerprint) {
			return nil, errors.New("runtime test store contains an invalid record")
		}
	}
	return store, nil
}

func (store *TestStore) Resolve(request TestRequest, digest string, run func() (TestResult, error)) (TestResult, bool, error) {
	store.mu.Lock()
	defer store.mu.Unlock()
	if record, exists := store.records[request.RequestID]; exists {
		if record.RequestDigest != digest || record.ConfigurationFingerprint != request.ConfigurationFingerprint ||
			record.Result.ExecutionMode != request.ExecutionMode {
			return TestResult{}, false, ErrTestConflict
		}
		return record.Result, true, nil
	}
	if len(store.records) >= maximumTestStoreRecords {
		return TestResult{}, false, ErrTestCapacity
	}
	result, err := run()
	if err != nil {
		return TestResult{}, false, err
	}
	if !validTestResult(result, request.ExecutionMode, request.ConfigurationFingerprint) {
		return TestResult{}, false, ErrInvalidTestResult
	}
	store.records[request.RequestID] = testStoreRecord{
		RequestDigest: digest, ConfigurationFingerprint: request.ConfigurationFingerprint, Result: result,
	}
	if err := store.persist(); err != nil {
		delete(store.records, request.RequestID)
		return TestResult{}, false, err
	}
	return result, false, nil
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
