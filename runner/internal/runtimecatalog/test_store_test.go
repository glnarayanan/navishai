package runtimecatalog

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

const testStoreCheckedAt = "2026-09-01T12:00:00Z"

func TestTestStoreRunsDifferentProbesWithoutHoldingStoreLock(t *testing.T) {
	store, err := OpenTestStore("")
	if err != nil {
		t.Fatal(err)
	}
	first := testStoreRequest("c9bb966b-1fe9-4304-bd51-404e4fd9a09c")
	second := testStoreRequest("3d07f334-88ef-4fe4-a640-421e3ba79921")
	started := make(chan string, 2)
	release := make(chan struct{})
	results := make(chan error, 2)
	resolve := func(request TestRequest, digest string) {
		_, _, resolveErr := store.Resolve(context.Background(), request, digest, func() (TestResult, error) {
			started <- request.RequestID
			<-release
			return testStoreResult(request), nil
		})
		results <- resolveErr
	}

	go resolve(first, strings.Repeat("a", 64))
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("first runtime probe did not start")
	}
	go resolve(second, strings.Repeat("b", 64))
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("second runtime probe waited on the first probe")
	}

	close(release)
	for range 2 {
		if resolveErr := <-results; resolveErr != nil {
			t.Fatalf("runtime probe failed: %v", resolveErr)
		}
	}
}

func TestTestStoreReplaysIdenticalInFlightRequestAndRejectsConflict(t *testing.T) {
	store, err := OpenTestStore("")
	if err != nil {
		t.Fatal(err)
	}
	request := testStoreRequest("c9bb966b-1fe9-4304-bd51-404e4fd9a09c")
	digest := strings.Repeat("a", 64)
	started := make(chan struct{}, 2)
	release := make(chan struct{})
	var calls atomic.Int32
	type resolveResult struct {
		replayed bool
		err      error
	}
	results := make(chan resolveResult, 2)
	run := func() (TestResult, error) {
		calls.Add(1)
		started <- struct{}{}
		<-release
		return testStoreResult(request), nil
	}
	go func() {
		_, replayed, resolveErr := store.Resolve(context.Background(), request, digest, run)
		results <- resolveResult{replayed: replayed, err: resolveErr}
	}()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("runtime probe did not start")
	}

	go func() {
		_, replayed, resolveErr := store.Resolve(context.Background(), request, digest, run)
		results <- resolveResult{replayed: replayed, err: resolveErr}
	}()
	select {
	case <-started:
		t.Fatal("identical in-flight request started a second probe")
	case <-time.After(20 * time.Millisecond):
	}

	if _, _, conflictErr := store.Resolve(context.Background(), request, strings.Repeat("b", 64), func() (TestResult, error) {
		t.Fatal("conflicting in-flight request ran a probe")
		return TestResult{}, nil
	}); !errors.Is(conflictErr, ErrTestConflict) {
		t.Fatalf("in-flight conflict error = %v, want %v", conflictErr, ErrTestConflict)
	}

	close(release)
	first := <-results
	second := <-results
	if calls.Load() != 1 {
		t.Fatalf("probe calls = %d, want 1", calls.Load())
	}
	if first.err != nil || second.err != nil {
		t.Fatalf("in-flight results failed: first=%v second=%v", first.err, second.err)
	}
	if first.replayed == second.replayed {
		t.Fatalf("replay markers = %v and %v, want one initial result and one replay", first.replayed, second.replayed)
	}
}

func TestTestStoreDoesNotRetainPersistFailure(t *testing.T) {
	path := filepath.Join(t.TempDir(), "runtime-tests.json")
	store, err := OpenTestStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	request := testStoreRequest("c9bb966b-1fe9-4304-bd51-404e4fd9a09c")
	_, replayed, err := store.Resolve(context.Background(), request, strings.Repeat("a", 64), func() (TestResult, error) {
		return testStoreResult(request), nil
	})
	if err == nil || replayed {
		t.Fatalf("persist failure result = (%v, %v), want error and no replay", err, replayed)
	}
	if _, exists := store.records[request.RequestID]; exists {
		t.Fatal("persist failure retained an in-memory record")
	}
}

func testStoreRequest(requestID string) TestRequest {
	return TestRequest{
		RequestID: requestID, ExecutionMode: protocol.ExecutionModeBounded,
		ConfigurationFingerprint: strings.Repeat("c", 64),
	}
}

func testStoreResult(request TestRequest) TestResult {
	checkedAt, _ := time.Parse(time.RFC3339, testStoreCheckedAt)
	return TestResult{
		Status: "passed", EffectiveModel: "fixture-model", ExecutionMode: request.ExecutionMode,
		ConfigurationFingerprint: request.ConfigurationFingerprint, TestedAt: checkedAt,
	}
}
