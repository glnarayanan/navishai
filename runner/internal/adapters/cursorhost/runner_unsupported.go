//go:build !darwin

package cursorhost

func platformSupported() bool { return false }

func newRunner() Runner { return nil }
