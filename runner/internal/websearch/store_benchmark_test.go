package websearch

import (
	"strings"
	"testing"
)

func BenchmarkStoreReplayWhileAnotherSearchBlocks(b *testing.B) {
	store, _ := OpenStore("")
	digest := strings.Repeat("a", 64)
	if _, _, err := store.Resolve("search:cached", digest, func() (Response, error) {
		return validStoreResponse("search:cached"), nil
	}); err != nil {
		b.Fatal(err)
	}
	started := make(chan struct{})
	release := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _, _ = store.Resolve("search:blocked", digest, func() (Response, error) {
			close(started)
			<-release
			return validStoreResponse("search:blocked"), nil
		})
	}()
	<-started
	b.Cleanup(func() {
		close(release)
		<-done
	})

	b.ResetTimer()
	for range b.N {
		if _, replayed, err := store.Resolve("search:cached", digest, func() (Response, error) {
			b.Fatal("cached provider called")
			return Response{}, nil
		}); err != nil || !replayed {
			b.Fatalf("replayed=%t err=%v", replayed, err)
		}
	}
}
