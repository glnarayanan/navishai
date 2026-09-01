package admission

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

func TestOpenStoreTerminalizesRetainedV1QueuedAndRunningRecords(t *testing.T) {
	tests := []struct {
		name      string
		phase     string
		delivered int
		extraType string
	}{
		{name: "queued with pending admission", phase: "queued", delivered: 0},
		{name: "queued after admission delivery", phase: "queued", delivered: 1},
		{name: "running with pending start", phase: "running", delivered: 1, extraType: "run.started"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "admissions.json")
			base := retainedV1StoreFixture(t)
			request := *base.Request
			at := time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)
			events := []protocol.CanonicalEvent{retainedV1AdmissionEvent(t, request, at)}
			if test.extraType != "" {
				events = append(events, retainedV1FollowupEvent(t, request, 2, test.extraType, at.Add(time.Second)))
			}
			writeRetainedV1Record(t, path, base, test.phase, test.delivered, events)

			store, err := OpenStore(path)
			if err != nil {
				t.Fatal(err)
			}
			record, ok := store.records[request.IdempotencyKey]
			if !ok || record.Phase != "terminal" || record.LastSequence != len(events)+1 {
				t.Fatalf("retained v1 record was not terminalized: %#v", record)
			}
			if len(record.Outbox) != len(events)-test.delivered+1 {
				t.Fatalf("retained v1 outbox lost ordering: delivered=%d record=%#v", test.delivered, record)
			}
			denial := record.Outbox[len(record.Outbox)-1]
			if denial.Sequence != record.LastSequence || denial.EventType != "run.policy_denied" ||
				denial.Data["code"] != retainedV1AdmissionDenialCode || denial.Data["tool"] != retainedV1AdmissionDenialTool {
				t.Fatalf("retained v1 record has the wrong terminal event: %#v", denial)
			}
			if _, ok := store.NextQueued(); ok || store.IsRunning(request.RunID) {
				t.Fatal("terminalized retained v1 record authorized execution")
			}
			if _, err := store.Claim(request.RunID); !errors.Is(err, ErrInvalidState) {
				t.Fatalf("terminalized retained v1 record was claimable: %v", err)
			}

			for expected := test.delivered + 1; expected <= len(events)+1; expected++ {
				pending, ok := store.NextEvent()
				if !ok || pending.Event.Sequence != expected {
					t.Fatalf("outbox sequence = %#v %t, want %d", pending, ok, expected)
				}
				if err := store.MarkDelivered(request.RunID, pending.Event.EventID); err != nil {
					t.Fatal(err)
				}
			}
			if _, ok := store.NextEvent(); ok {
				t.Fatal("terminalized retained v1 record retained an outbox event after delivery")
			}
		})
	}
}

func TestOpenStoreLeavesAlreadyTerminalRetainedV1RecordWithoutDuplicateEvent(t *testing.T) {
	for _, delivered := range []int{1, 2} {
		t.Run(fmt.Sprintf("delivered_%d", delivered), func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "admissions.json")
			base := retainedV1StoreFixture(t)
			request := *base.Request
			at := time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)
			events := []protocol.CanonicalEvent{
				retainedV1AdmissionEvent(t, request, at),
				retainedV1FollowupEvent(t, request, 2, "run.failed", at.Add(time.Second)),
			}
			writeRetainedV1Record(t, path, base, "terminal", delivered, events)

			store, err := OpenStore(path)
			if err != nil {
				t.Fatal(err)
			}
			first := store.records[request.IdempotencyKey]
			if first.Phase != "terminal" || first.LastSequence != 2 {
				t.Fatalf("already-terminal retained v1 record changed unexpectedly: %#v", first)
			}
			persisted, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			reopened, err := OpenStore(path)
			if err != nil {
				t.Fatal(err)
			}
			second := reopened.records[request.IdempotencyKey]
			if second.LastSequence != first.LastSequence || len(second.Outbox) != len(first.Outbox) {
				t.Fatalf("reopen changed an already-terminal record: first=%#v second=%#v", first, second)
			}
			reopenedBytes, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if string(reopenedBytes) != string(persisted) {
				t.Fatal("reopening an already-terminal retained v1 record created new event state")
			}
		})
	}
}

func TestOpenStoreRewritesPreviousRetainedV1PhaseUsingCurrentPhaseVocabulary(t *testing.T) {
	path := filepath.Join(t.TempDir(), "admissions.json")
	base := retainedV1StoreFixture(t)
	request := *base.Request
	at := time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)
	events := []protocol.CanonicalEvent{retainedV1AdmissionEvent(t, request, at)}
	writeRetainedV1Record(t, path, base, "legacy", 0, events)

	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	record := store.records[request.IdempotencyKey]
	if record.Phase != "terminal" || record.LastSequence != 2 {
		t.Fatalf("previous retained v1 phase was not migrated: %#v", record)
	}

	persisted, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var records map[string]map[string]any
	if err := json.Unmarshal(persisted, &records); err != nil {
		t.Fatal(err)
	}
	if records[request.IdempotencyKey]["phase"] != "terminal" {
		t.Fatalf("retained v1 state was not durably rewritten: %#v", records[request.IdempotencyKey])
	}
	if _, exists := records[request.IdempotencyKey]["legacy"]; exists {
		t.Fatalf("legacy marker was unnecessarily persisted: %#v", records[request.IdempotencyKey])
	}
	if strings.Contains(string(persisted), `"phase":"legacy"`) {
		t.Fatalf("persisted state still contains the removed legacy phase: %s", persisted)
	}
}

func retainedV1StoreFixture(t *testing.T) Record {
	t.Helper()
	path := filepath.Join("..", "..", "..", "test", "fixtures", "files", "runner_protocol", "retained_v1", "admissions.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var records map[string]Record
	if err := json.Unmarshal(data, &records); err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 {
		t.Fatalf("retained v1 fixture must contain one record: %#v", records)
	}
	for _, record := range records {
		if record.Request == nil || record.Request.ProtocolVersion != protocol.Version {
			t.Fatalf("fixture is not a retained v1 record: %#v", record)
		}
		return record
	}
	panic("unreachable")
}

func writeRetainedV1Record(t *testing.T, path string, base Record, phase string, delivered int, events []protocol.CanonicalEvent) {
	t.Helper()
	record := base
	record.Response.Event = events[0]
	record.Phase = phase
	record.LastSequence = len(events)
	record.LastOccurredAt = events[len(events)-1].OccurredAt
	record.DeliveredSequence = delivered
	record.Outbox = events[delivered:]
	data, err := json.Marshal(map[string]Record{record.Request.IdempotencyKey: record})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func retainedV1AdmissionEvent(t *testing.T, request protocol.AdmissionRequest, at time.Time) protocol.CanonicalEvent {
	t.Helper()
	event, err := protocol.NewCanonicalEvent(request.RunID, 1, "run.admitted", at, map[string]any{
		"workspace_key": request.WorkspaceKey, "task_key": request.Task.TaskKey, "attempt": request.Task.Attempt,
	})
	if err != nil {
		t.Fatal(err)
	}
	return event
}

func retainedV1FollowupEvent(t *testing.T, request protocol.AdmissionRequest, sequence int, eventType string, at time.Time) protocol.CanonicalEvent {
	t.Helper()
	data := map[string]any{}
	switch eventType {
	case "run.started":
		data = map[string]any{"adapter": request.Routing.AdapterKey, "scenario": "retained_v1", "attempt": request.Task.Attempt}
	case "run.failed":
		data = map[string]any{"code": "retained_v1_fixture_failure", "retryable": false}
	default:
		t.Fatalf("unsupported retained v1 follow-up event %q", eventType)
	}
	event, err := protocol.NewCanonicalEvent(request.RunID, sequence, eventType, at, data)
	if err != nil {
		t.Fatal(err)
	}
	return event
}
