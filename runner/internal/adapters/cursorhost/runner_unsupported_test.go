//go:build !darwin

package cursorhost

import (
	"context"
	"errors"
	"testing"
)

func TestCursorHostSourceIsUnsupportedOffDarwin(t *testing.T) {
	source := New(nil)
	if source.Supported() {
		t.Fatal("non-Darwin Cursor host source reported support")
	}
	if _, err := source.DiscoverModels(context.Background(), "", "", ""); !errors.Is(err, ErrUnsupportedPlatform) {
		t.Fatalf("non-Darwin model discovery was not rejected: %v", err)
	}
}
