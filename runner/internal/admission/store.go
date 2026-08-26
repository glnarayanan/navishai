package admission

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

const (
	maximumRecords = 100_000
	maximumBytes   = 64 * 1024 * 1024
)

var (
	ErrConflict          = errors.New("idempotency key already has a different request")
	ErrCapacity          = errors.New("runner admission store reached its capacity")
	ErrInvalidState      = errors.New("runner admission state is invalid")
	errDurabilityUnknown = errors.New("admission state durability is unknown")
)

type Record struct {
	RequestDigest     string                     `json:"request_digest"`
	Request           *protocol.AdmissionRequest `json:"request,omitempty"`
	Response          protocol.AdmissionResponse `json:"response"`
	Phase             string                     `json:"phase,omitempty"`
	LastSequence      int                        `json:"last_sequence,omitempty"`
	LastOccurredAt    time.Time                  `json:"last_occurred_at,omitempty"`
	DeliveredSequence int                        `json:"delivered_sequence,omitempty"`
	Outbox            []protocol.CanonicalEvent  `json:"outbox,omitempty"`
}

type PendingEvent struct {
	RunID        string
	WorkspaceKey string
	Event        protocol.CanonicalEvent
}

type Store struct {
	mu        sync.Mutex
	path      string
	records   map[string]Record
	runKeys   map[string]string
	sortedIDs []string
}

func OpenStore(path string) (*Store, error) {
	store := &Store{
		path: path, records: make(map[string]Record), runKeys: make(map[string]string),
	}
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
	if err := store.validate(); err != nil {
		return nil, err
	}
	store.indexRecords()
	return store, nil
}

func (store *Store) Admit(request protocol.AdmissionRequest, digest string, response protocol.AdmissionResponse) (protocol.AdmissionResponse, bool, error) {
	store.mu.Lock()
	defer store.mu.Unlock()

	key := request.IdempotencyKey
	if record, exists := store.records[key]; exists {
		if record.RequestDigest != digest {
			return protocol.AdmissionResponse{}, false, ErrConflict
		}
		return record.Response, true, nil
	}
	if _, exists := store.runKeys[request.RunID]; exists {
		return protocol.AdmissionResponse{}, false, ErrConflict
	}
	if len(store.records) >= maximumRecords {
		return protocol.AdmissionResponse{}, false, ErrCapacity
	}
	requestCopy := request
	store.records[key] = Record{
		RequestDigest: digest, Request: &requestCopy, Response: response, Phase: "queued",
		LastSequence: 1, LastOccurredAt: response.Event.OccurredAt,
		Outbox: []protocol.CanonicalEvent{response.Event},
	}
	store.runKeys[request.RunID] = key
	store.insertSortedID(key)
	if err := store.persist(); err != nil {
		if !errors.Is(err, errDurabilityUnknown) {
			delete(store.records, key)
			delete(store.runKeys, request.RunID)
			store.removeSortedID(key)
		}
		return protocol.AdmissionResponse{}, false, err
	}
	return response, false, nil
}

func (store *Store) NextEvent() (PendingEvent, bool) {
	store.mu.Lock()
	defer store.mu.Unlock()

	keys := store.sortedKeys()
	for _, key := range keys {
		record := store.records[key]
		if record.Request != nil && len(record.Outbox) > 0 {
			return PendingEvent{
				RunID: record.Response.RunID, WorkspaceKey: record.Request.WorkspaceKey, Event: record.Outbox[0],
			}, true
		}
	}
	return PendingEvent{}, false
}

func (store *Store) MarkDelivered(runID, eventID string) error {
	store.mu.Lock()
	defer store.mu.Unlock()

	key, record, ok := store.recordForRun(runID)
	if !ok || len(record.Outbox) == 0 || record.Outbox[0].EventID != eventID ||
		record.Outbox[0].Sequence != record.DeliveredSequence+1 {
		return ErrInvalidState
	}
	record.DeliveredSequence = record.Outbox[0].Sequence
	record.Outbox = append([]protocol.CanonicalEvent(nil), record.Outbox[1:]...)
	return store.replace(key, store.records[key], record)
}

func (store *Store) NextQueued() (protocol.AdmissionRequest, bool) {
	store.mu.Lock()
	defer store.mu.Unlock()

	for _, key := range store.sortedKeys() {
		record := store.records[key]
		if record.Request != nil && record.Phase == "queued" && record.DeliveredSequence == 1 && len(record.Outbox) == 0 {
			return *record.Request, true
		}
	}
	return protocol.AdmissionRequest{}, false
}

func (store *Store) Claim(runID string) (protocol.AdmissionRequest, error) {
	store.mu.Lock()
	defer store.mu.Unlock()

	key, record, ok := store.recordForRun(runID)
	if !ok || record.Request == nil || record.Phase != "queued" || record.DeliveredSequence != 1 || len(record.Outbox) != 0 {
		return protocol.AdmissionRequest{}, ErrInvalidState
	}
	record.Phase = "running"
	if err := store.replace(key, store.records[key], record); err != nil {
		return protocol.AdmissionRequest{}, err
	}
	return *record.Request, nil
}

func (store *Store) Running() []protocol.AdmissionRequest {
	store.mu.Lock()
	defer store.mu.Unlock()

	result := []protocol.AdmissionRequest{}
	for _, key := range store.sortedKeys() {
		record := store.records[key]
		if record.Request != nil && record.Phase == "running" {
			result = append(result, *record.Request)
		}
	}
	return result
}

func (store *Store) LastSequence(runID string) (int, error) {
	store.mu.Lock()
	defer store.mu.Unlock()

	_, record, ok := store.recordForRun(runID)
	if !ok || record.Request == nil {
		return 0, ErrInvalidState
	}
	return record.LastSequence, nil
}

func (store *Store) LastOccurredAt(runID string) (time.Time, error) {
	store.mu.Lock()
	defer store.mu.Unlock()

	_, record, ok := store.recordForRun(runID)
	if !ok || record.Request == nil {
		return time.Time{}, ErrInvalidState
	}
	return record.LastOccurredAt, nil
}

func (store *Store) IsRunning(runID string) bool {
	store.mu.Lock()
	defer store.mu.Unlock()

	_, record, ok := store.recordForRun(runID)
	return ok && record.Request != nil && record.Phase == "running"
}

func (store *Store) AppendEvent(runID string, event protocol.CanonicalEvent) error {
	store.mu.Lock()
	defer store.mu.Unlock()

	key, record, ok := store.recordForRun(runID)
	if !ok || record.Request == nil || record.Phase != "running" || event.RunID != runID ||
		event.Sequence != record.LastSequence+1 || event.Validate() != nil || event.OccurredAt.Before(record.LastOccurredAt) {
		return ErrInvalidState
	}
	record.LastSequence = event.Sequence
	record.LastOccurredAt = event.OccurredAt
	record.Outbox = append(record.Outbox, event)
	if terminalEvent(event.EventType) {
		record.Phase = "terminal"
	}
	return store.replace(key, store.records[key], record)
}

func terminalEvent(eventType string) bool {
	switch eventType {
	case "run.completed", "run.failed", "run.timed_out", "run.canceled", "run.policy_denied":
		return true
	default:
		return false
	}
}

func (store *Store) recordForRun(runID string) (string, Record, bool) {
	key, ok := store.runKeys[runID]
	if !ok {
		return "", Record{}, false
	}
	return key, store.records[key], true
}

func (store *Store) sortedKeys() []string {
	return store.sortedIDs
}

func (store *Store) indexRecords() {
	store.sortedIDs = make([]string, 0, len(store.records))
	for key, record := range store.records {
		store.sortedIDs = append(store.sortedIDs, key)
		store.runKeys[record.Response.RunID] = key
	}
	sort.Strings(store.sortedIDs)
}

func (store *Store) insertSortedID(key string) {
	index := sort.SearchStrings(store.sortedIDs, key)
	store.sortedIDs = append(store.sortedIDs, "")
	copy(store.sortedIDs[index+1:], store.sortedIDs[index:])
	store.sortedIDs[index] = key
}

func (store *Store) removeSortedID(key string) {
	index := sort.SearchStrings(store.sortedIDs, key)
	if index == len(store.sortedIDs) || store.sortedIDs[index] != key {
		return
	}
	store.sortedIDs = append(store.sortedIDs[:index], store.sortedIDs[index+1:]...)
}

func (store *Store) validate() error {
	runs := make(map[string]bool, len(store.records))
	for _, record := range store.records {
		if runs[record.Response.RunID] {
			return ErrInvalidState
		}
		runs[record.Response.RunID] = true
		if record.Request == nil {
			continue
		}
		if record.Request.Validate() != nil || record.Request.RunID != record.Response.RunID ||
			(record.Phase != "queued" && record.Phase != "running" && record.Phase != "terminal") ||
			record.DeliveredSequence < 0 || record.LastSequence < record.DeliveredSequence || record.LastSequence < 1 ||
			record.LastOccurredAt.IsZero() || record.Response.Event.Validate() != nil ||
			record.Response.Event.RunID != record.Request.RunID || record.Response.Event.Sequence != 1 ||
			record.Response.Event.EventType != "run.admitted" || !admissionAttemptMatches(record) ||
			record.Response.Event.Data["workspace_key"] != record.Request.WorkspaceKey ||
			record.Response.Event.Data["task_key"] != record.Request.Task.TaskKey {
			return ErrInvalidState
		}
		next := record.DeliveredSequence + 1
		previousAt := time.Time{}
		if record.DeliveredSequence == 0 {
			previousAt = record.Response.Event.OccurredAt
		}
		for _, event := range record.Outbox {
			if event.Validate() != nil || event.RunID != record.Response.RunID || event.Sequence != next ||
				event.OccurredAt.After(record.LastOccurredAt) || (!previousAt.IsZero() && event.OccurredAt.Before(previousAt)) {
				return ErrInvalidState
			}
			previousAt = event.OccurredAt
			next++
		}
		if next-1 != record.LastSequence || len(record.Outbox) > 0 && !previousAt.Equal(record.LastOccurredAt) {
			return ErrInvalidState
		}
	}
	return nil
}

func admissionAttemptMatches(record Record) bool {
	attempt := record.Response.Event.Data["attempt"]
	return attempt == record.Request.Task.Attempt || attempt == float64(record.Request.Task.Attempt)
}

func (store *Store) replace(key string, previous, current Record) error {
	store.records[key] = current
	if err := store.persist(); err != nil {
		if !errors.Is(err, errDurabilityUnknown) {
			store.records[key] = previous
		}
		return err
	}
	return nil
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
