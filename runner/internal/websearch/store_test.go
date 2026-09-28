package websearch

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

func TestStoreCoalescesMatchingRequestsAndRejectsInflightConflict(t *testing.T) {
	synctest.Test(t, testStoreCoalescesMatchingRequestsAndRejectsInflightConflict)
}

func testStoreCoalescesMatchingRequestsAndRejectsInflightConflict(t *testing.T) {
	path := filepath.Join(t.TempDir(), "searches.json")
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	started := make(chan struct{})
	release := make(chan struct{})
	digest := strings.Repeat("a", 64)
	result := make(chan error, 2)
	go func() {
		_, replayed, resolveErr := store.Resolve("search:coalesced", digest, func() (Response, error) {
			close(started)
			<-release
			return validStoreResponse("search:coalesced"), nil
		})
		if replayed && resolveErr == nil {
			resolveErr = errors.New("leader was marked as replayed")
		}
		result <- resolveErr
	}()
	<-started
	go func() {
		_, replayed, resolveErr := store.Resolve("search:coalesced", digest, func() (Response, error) {
			return Response{}, errors.New("coalesced search ran")
		})
		if !replayed && resolveErr == nil {
			resolveErr = errors.New("waiter was not marked as replayed")
		}
		result <- resolveErr
	}()
	synctest.Wait()
	if _, _, err := store.Resolve("search:coalesced", strings.Repeat("b", 64), func() (Response, error) {
		return Response{}, errors.New("conflicting search ran")
	}); !errors.Is(err, ErrConflict) {
		t.Fatalf("in-flight conflict = %v", err)
	}
	close(release)
	for range 2 {
		if err := <-result; err != nil {
			t.Fatal(err)
		}
	}
	reopened, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, replayed, err := reopened.Resolve("search:coalesced", digest, func() (Response, error) {
		return Response{}, errors.New("persisted search ran")
	}); err != nil || !replayed {
		t.Fatalf("reopen replayed=%t err=%v", replayed, err)
	}
}

func TestStoreFailureReleasesWaitersAndAllowsRetry(t *testing.T) {
	synctest.Test(t, testStoreFailureReleasesWaitersAndAllowsRetry)
}

func testStoreFailureReleasesWaitersAndAllowsRetry(t *testing.T) {
	store, _ := OpenStore("")
	digest := strings.Repeat("a", 64)
	started := make(chan struct{})
	release := make(chan struct{})
	failure := errors.New("provider failed")
	results := make(chan error, 2)
	go func() {
		_, _, err := store.Resolve("search:retry", digest, func() (Response, error) {
			close(started)
			<-release
			return Response{}, failure
		})
		results <- err
	}()
	<-started
	go func() {
		_, _, err := store.Resolve("search:retry", digest, func() (Response, error) {
			return Response{}, errors.New("coalesced search ran")
		})
		results <- err
	}()
	synctest.Wait()
	close(release)
	for range 2 {
		if err := <-results; !errors.Is(err, failure) {
			t.Fatalf("failure = %v", err)
		}
	}
	if _, replayed, err := store.Resolve("search:retry", digest, func() (Response, error) {
		return validStoreResponse("search:retry"), nil
	}); err != nil || replayed {
		t.Fatalf("retry replayed=%t err=%v", replayed, err)
	}
}

func TestStoreDoesNotPublishResponseWhenPersistenceFails(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "not-a-directory")
	path := filepath.Join(directory, "searches.json")
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(directory, []byte("block directory creation"), 0o600); err != nil {
		t.Fatal(err)
	}
	digest := strings.Repeat("a", 64)
	calls := 0
	for range 2 {
		if _, replayed, err := store.Resolve("search:persistence", digest, func() (Response, error) {
			calls++
			return validStoreResponse("search:persistence"), nil
		}); err == nil || replayed {
			t.Fatalf("persistence failure replayed=%t err=%v", replayed, err)
		}
	}
	if calls != 2 {
		t.Fatalf("provider calls = %d, want 2", calls)
	}
}

func TestStoreBoundsProviderConcurrency(t *testing.T) {
	synctest.Test(t, testStoreBoundsProviderConcurrency)
}

func testStoreBoundsProviderConcurrency(t *testing.T) {
	path := filepath.Join(t.TempDir(), "searches.json")
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	digest := strings.Repeat("a", 64)
	if _, _, err := store.Resolve("search:cached", digest, func() (Response, error) {
		return validStoreResponse("search:cached"), nil
	}); err != nil {
		t.Fatal(err)
	}
	release := make(chan struct{})
	started := make(chan struct{}, maximumConcurrentSearches+1)
	var calls atomic.Int32
	var wait sync.WaitGroup
	for index := range maximumConcurrentSearches + 1 {
		wait.Add(1)
		go func(index int) {
			defer wait.Done()
			key := "search:bounded:" + string(rune('a'+index))
			_, _, err := store.Resolve(key, digest, func() (Response, error) {
				calls.Add(1)
				started <- struct{}{}
				<-release
				return validStoreResponse(key), nil
			})
			if err != nil {
				t.Error(err)
			}
		}(index)
	}
	for range maximumConcurrentSearches {
		<-started
	}
	synctest.Wait()
	if calls.Load() != maximumConcurrentSearches {
		t.Fatalf("provider calls = %d, want %d", calls.Load(), maximumConcurrentSearches)
	}
	if _, replayed, err := store.Resolve("search:cached", digest, func() (Response, error) {
		return Response{}, errors.New("cached provider called")
	}); err != nil || !replayed {
		t.Fatalf("cached replay while providers block: replay=%t error=%v", replayed, err)
	}
	close(release)
	wait.Wait()
	if calls.Load() != maximumConcurrentSearches+1 {
		t.Fatalf("queued provider never ran: %d calls", calls.Load())
	}
	reopened, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(reopened.records) != maximumConcurrentSearches+2 {
		t.Fatalf("concurrent commits lost records: %d", len(reopened.records))
	}
}

func TestStoreReservesCapacityBeforeCallingProvider(t *testing.T) {
	store, _ := OpenStore("")
	for index := range maximumStoreRecords - 1 {
		store.records[fmt.Sprintf("retained:%d", index)] = storeRecord{}
	}
	started, release, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
	go func() {
		defer close(done)
		_, _, _ = store.Resolve("search:last-slot", strings.Repeat("a", 64), func() (Response, error) {
			close(started)
			<-release
			return Response{}, errors.New("release reservation")
		})
	}()
	<-started
	_, _, err := store.Resolve("search:overflow", strings.Repeat("a", 64), func() (Response, error) {
		return Response{}, errors.New("provider must not run without capacity")
	})
	close(release)
	<-done
	if !errors.Is(err, ErrCapacity) {
		t.Fatalf("capacity error = %v", err)
	}
}

func validStoreResponse(key string) Response {
	return Response{
		ProtocolVersion: protocol.Version,
		WorkspaceKey:    "c9bb966b-1fe9-4304-bd51-404e4fd9a09c",
		RequestKey:      key,
		Query:           "status query",
		ProviderKey:     "fixture",
		PolicyDecision:  "allowed",
		RetrievedAt:     searchNow,
		Results:         []Result{},
	}
}
