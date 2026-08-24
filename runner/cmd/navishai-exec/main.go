//go:build linux && amd64

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"syscall"

	"github.com/glnarayanan/navishai/runner/internal/isolation"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "missing executable")
		os.Exit(125)
	}
	limits, err := configuredLimits()
	if err != nil {
		fmt.Fprintln(os.Stderr, "invalid execution limits")
		os.Exit(125)
	}
	var readRoots, writeRoots []string
	if json.Unmarshal([]byte(os.Getenv("NAVISHAI_EXEC_READ_ROOTS")), &readRoots) != nil ||
		json.Unmarshal([]byte(os.Getenv("NAVISHAI_EXEC_WRITE_ROOTS")), &writeRoots) != nil {
		fmt.Fprintln(os.Stderr, "invalid filesystem roots")
		os.Exit(125)
	}
	if err := isolation.Apply(
		limits, os.Getenv("NAVISHAI_DENY_NETWORK") == "1", os.Getenv("NAVISHAI_EXEC_ALLOW_NETWORK") == "1",
		readRoots, writeRoots,
	); err != nil {
		fmt.Fprintln(os.Stderr, "cannot apply execution isolation")
		os.Exit(125)
	}
	if err := syscall.Exec(os.Args[1], os.Args[1:], targetEnvironment()); err != nil {
		fmt.Fprintln(os.Stderr, "cannot start approved executable")
		os.Exit(126)
	}
}

func targetEnvironment() []string {
	result := make([]string, 0, len(os.Environ()))
	for _, value := range os.Environ() {
		if !strings.HasPrefix(value, "NAVISHAI_EXEC_") && !strings.HasPrefix(value, "NAVISHAI_LIMIT_") && value != "NAVISHAI_DENY_NETWORK=1" {
			result = append(result, value)
		}
	}
	return result
}

func configuredLimits() (isolation.Limits, error) {
	values := make([]uint64, 4)
	for index, key := range []string{
		"NAVISHAI_LIMIT_CPU_SECONDS", "NAVISHAI_LIMIT_MEMORY_BYTES",
		"NAVISHAI_LIMIT_OPEN_FILES", "NAVISHAI_LIMIT_PROCESSES",
	} {
		value, err := strconv.ParseUint(os.Getenv(key), 10, 64)
		if err != nil {
			return isolation.Limits{}, err
		}
		values[index] = value
	}
	return isolation.Limits{
		CPUSeconds: values[0], MemoryBytes: values[1], OpenFiles: values[2], Processes: values[3],
	}, nil
}
