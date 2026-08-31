//go:build !linux || !amd64

package supervisor

import (
	"context"
	"errors"
	"io"
	"testing"
)

func TestUnsupportedPlatformFailsClosed(t *testing.T) {
	instance, err := New(Config{})
	if instance == nil || err != nil {
		t.Fatalf("New() = %#v, %v; want inert supervisor", instance, err)
	}

	if _, err := instance.Run(context.Background(), Request{}); !errors.Is(err, ErrUnsupportedPlatform) {
		t.Fatalf("Run() error = %v; want unsupported-platform error", err)
	}
	if _, err := instance.Interact(context.Background(), Request{}, func(context.Context, io.ReadWriter) error { return nil }); !errors.Is(err, ErrUnsupportedPlatform) {
		t.Fatal("Interact() unexpectedly allowed process execution")
	}
}
