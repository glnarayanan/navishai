package admission

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

func BenchmarkStorePersistedLifecycle(b *testing.B) {
	for _, retained := range []int{100, 1_000} {
		b.Run(fmt.Sprintf("retained_%d", retained), func(b *testing.B) {
			store, base, at := benchmarkPersistedStore(b, retained)
			baseline, err := os.ReadFile(store.path)
			if err != nil {
				b.Fatal(err)
			}
			if len(baseline) >= maximumBytes {
				b.Fatalf("fixture is at or above capacity: %d bytes", len(baseline))
			}
			b.ReportAllocs()
			b.ResetTimer()
			b.ReportMetric(float64(len(baseline)), "retained-B")
			b.StopTimer()

			for index := 0; index < b.N; index++ {
				if err := os.WriteFile(store.path, baseline, 0o600); err != nil {
					b.Fatal(err)
				}
				store, err = OpenStore(store.path)
				if err != nil {
					b.Fatal(err)
				}
				b.StartTimer()
				request, response := benchmarkAdmission(b, base, retained+index+1, at)
				if _, _, err := store.Admit(request, fmt.Sprintf("%064x", retained+index+1), response); err != nil {
					b.Fatal(err)
				}
				benchmarkAcknowledge(b, store, request.RunID)
				if _, err := store.Claim(request.RunID); err != nil {
					b.Fatal(err)
				}
				benchmarkAppendAndAcknowledge(b, store, request, 2, "run.started", at.Add(time.Second))
				benchmarkAppendAndAcknowledge(b, store, request, 3, "run.completed", at.Add(2*time.Second))
				b.StopTimer()
			}
		})
	}
}

func BenchmarkStoreScanPastRetainedHistory(b *testing.B) {
	for _, retained := range []int{100, 1_000, 10_000} {
		b.Run(fmt.Sprintf("retained_%d", retained), func(b *testing.B) {
			b.Run("next_event_miss", func(b *testing.B) {
				store, _, _ := benchmarkStore(b, retained)
				b.ResetTimer()
				for b.Loop() {
					if _, ok := store.NextEvent(); ok {
						b.Fatal("expected delivered terminal history")
					}
				}
			})

			b.Run("next_event_at_end", func(b *testing.B) {
				store, base, at := benchmarkStore(b, retained)
				request, response := benchmarkAdmission(b, base, retained+1, at)
				if _, _, err := store.Admit(request, fmt.Sprintf("%064x", retained+1), response); err != nil {
					b.Fatal(err)
				}
				b.ResetTimer()
				for b.Loop() {
					pending, ok := store.NextEvent()
					if !ok || pending.RunID != request.RunID {
						b.Fatal("expected pending event after terminal history")
					}
				}
			})

			b.Run("next_queued_at_end", func(b *testing.B) {
				store, base, at := benchmarkStore(b, retained)
				request, response := benchmarkAdmission(b, base, retained+1, at)
				if _, _, err := store.Admit(request, fmt.Sprintf("%064x", retained+1), response); err != nil {
					b.Fatal(err)
				}
				benchmarkAcknowledge(b, store, request.RunID)
				b.ResetTimer()
				for b.Loop() {
					queued, ok := store.NextQueued()
					if !ok || queued.RunID != request.RunID {
						b.Fatal("expected queued run after terminal history")
					}
				}
			})
		})
	}
}

func benchmarkPersistedStore(b *testing.B, size int) (*Store, protocol.AdmissionRequest, time.Time) {
	b.Helper()
	store, base, at := benchmarkStore(b, size)
	data, err := json.Marshal(store.records)
	if err != nil {
		b.Fatal(err)
	}
	path := filepath.Join(b.TempDir(), "runs.json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		b.Fatal(err)
	}
	persisted, err := OpenStore(path)
	if err != nil {
		b.Fatal(err)
	}
	return persisted, base, at
}

func benchmarkStore(b *testing.B, size int) (*Store, protocol.AdmissionRequest, time.Time) {
	b.Helper()
	body, err := os.ReadFile(filepath.Join("..", "..", "..", "test", "fixtures", "files", "runner_protocol", "v2", "admission_request.json"))
	if err != nil {
		b.Fatal(err)
	}
	base, err := protocol.DecodeAdmissionBytes(body)
	if err != nil {
		b.Fatal(err)
	}
	store, err := OpenStore("")
	if err != nil {
		b.Fatal(err)
	}
	at := time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)
	for index := range size {
		request, response := benchmarkAdmission(b, base, index+1, at)
		requestCopy := request
		store.records[request.IdempotencyKey] = Record{
			RequestDigest:     fmt.Sprintf("%064x", index+1),
			Request:           &requestCopy,
			Response:          response,
			Phase:             "terminal",
			LastSequence:      3,
			LastOccurredAt:    at.Add(2 * time.Second),
			DeliveredSequence: 3,
		}
	}
	store.indexRecords()
	return store, base, at
}

func benchmarkAdmission(b *testing.B, base protocol.AdmissionRequest, index int, at time.Time) (protocol.AdmissionRequest, protocol.AdmissionResponse) {
	b.Helper()
	suffix := fmt.Sprintf("%012x", index)
	request := base
	request.RunID = "3d07f334-88ef-4fe4-a640-" + suffix
	request.IdempotencyKey = "benchmark:" + suffix
	request.Task.TaskKey = "8e74b9af-98d7-4cbf-9dc9-" + suffix
	event, err := protocol.NewCanonicalEvent(request.RunID, 1, "run.admitted", at, map[string]any{
		"workspace_key": request.WorkspaceKey,
		"task_key":      request.Task.TaskKey,
		"attempt":       request.Task.Attempt,
	})
	if err != nil {
		b.Fatal(err)
	}
	return request, protocol.AdmissionResponse{
		ProtocolVersion: protocol.AdmissionVersion,
		RunID:           request.RunID,
		Status:          "accepted",
		Event:           event,
	}
}

func benchmarkAppendAndAcknowledge(b *testing.B, store *Store, request protocol.AdmissionRequest, sequence int, eventType string, at time.Time) {
	b.Helper()
	data := map[string]any{
		"adapter": "scripted", "scenario": "benchmark", "attempt": request.Task.Attempt,
	}
	if eventType == "run.completed" {
		data = map[string]any{"outcome": "completed"}
	}
	event, err := protocol.NewCanonicalEvent(request.RunID, sequence, eventType, at, data)
	if err != nil {
		b.Fatal(err)
	}
	if err := store.AppendEvent(request.RunID, event); err != nil {
		b.Fatal(err)
	}
	benchmarkAcknowledge(b, store, request.RunID)
}

func benchmarkAcknowledge(b *testing.B, store *Store, runID string) {
	b.Helper()
	pending, ok := store.NextEvent()
	if !ok || pending.RunID != runID {
		b.Fatalf("expected pending event for %s", runID)
	}
	if err := store.MarkDelivered(runID, pending.Event.EventID); err != nil {
		b.Fatal(err)
	}
}
