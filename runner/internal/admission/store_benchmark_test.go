package admission

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

func BenchmarkStoreLookupWithTenThousandRuns(b *testing.B) {
	store, lastRunID := benchmarkStore(b, 10_000)

	b.Run("next event", func(b *testing.B) {
		for b.Loop() {
			if _, ok := store.NextEvent(); !ok {
				b.Fatal("expected a pending event")
			}
		}
	})

	b.Run("last sequence", func(b *testing.B) {
		for b.Loop() {
			if _, err := store.LastSequence(lastRunID); err != nil {
				b.Fatal(err)
			}
		}
	})
}

func benchmarkStore(b *testing.B, size int) (*Store, string) {
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
	lastRunID := ""
	for index := range size {
		suffix := fmt.Sprintf("%012x", index+1)
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
		response := protocol.AdmissionResponse{
			ProtocolVersion: protocol.AdmissionVersion,
			RunID:           request.RunID,
			Status:          "accepted",
			Event:           event,
		}
		if _, _, err := store.Admit(request, fmt.Sprintf("%064x", index+1), response); err != nil {
			b.Fatal(err)
		}
		lastRunID = request.RunID
	}
	return store, lastRunID
}
