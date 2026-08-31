package adapters

import (
	"bufio"
	"bytes"
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	MaxModelDiscoveryOutputBytes = 64 * 1024
	MaxModelDiscoveryLines       = 512
	MaxModelDiscoveryLineBytes   = 8 * 1024
	MaxModelOptions              = 100
	MaxModelIDBytes              = 200
	MaxModelLabelBytes           = 200
)

var ErrInvalidModelDiscovery = errors.New("invalid model discovery output")

type ModelOption struct {
	ID      string
	Label   string
	Default bool
}

type ModelDiscoverySpec struct {
	Arguments []string
	Parse     func([]byte) ([]ModelOption, error)
}

func ValidateModelOptions(options []ModelOption) error {
	if len(options) == 0 || len(options) > MaxModelOptions {
		return ErrInvalidModelDiscovery
	}
	seen := make(map[string]struct{}, len(options))
	defaults := 0
	for _, option := range options {
		if !validModelText(option.ID, MaxModelIDBytes) || strings.TrimSpace(option.ID) != option.ID ||
			!validModelText(option.Label, MaxModelLabelBytes) || strings.TrimSpace(option.Label) != option.Label {
			return ErrInvalidModelDiscovery
		}
		if _, exists := seen[option.ID]; exists {
			return ErrInvalidModelDiscovery
		}
		seen[option.ID] = struct{}{}
		if option.Default {
			defaults++
		}
	}
	if defaults > 1 {
		return ErrInvalidModelDiscovery
	}
	return nil
}

func ParseModelLines(body []byte) ([]ModelOption, error) {
	if err := ValidateModelDiscoveryOutput(body); err != nil {
		return nil, ErrInvalidModelDiscovery
	}
	scanner := bufio.NewScanner(bytes.NewReader(body))
	scanner.Buffer(make([]byte, 1024), MaxModelDiscoveryLineBytes)
	options := make([]ModelOption, 0)
	lines := 0
	for scanner.Scan() {
		lines++
		if lines > MaxModelDiscoveryLines {
			return nil, ErrInvalidModelDiscovery
		}
		line := scanner.Text()
		if line == "" {
			continue
		}
		if strings.IndexFunc(line, unicode.IsSpace) >= 0 {
			return nil, ErrInvalidModelDiscovery
		}
		options = append(options, ModelOption{ID: line, Label: line})
	}
	if scanner.Err() != nil {
		return nil, ErrInvalidModelDiscovery
	}
	if err := ValidateModelOptions(options); err != nil {
		return nil, err
	}
	return options, nil
}

func ValidateModelDiscoveryOutput(body []byte) error {
	if !boundedModelDiscoveryBody(body) {
		return ErrInvalidModelDiscovery
	}
	scanner := bufio.NewScanner(bytes.NewReader(body))
	scanner.Buffer(make([]byte, 1024), MaxModelDiscoveryLineBytes)
	lines := 0
	for scanner.Scan() {
		lines++
		if lines > MaxModelDiscoveryLines {
			return ErrInvalidModelDiscovery
		}
	}
	if scanner.Err() != nil {
		return ErrInvalidModelDiscovery
	}
	return nil
}

func boundedModelDiscoveryBody(body []byte) bool {
	return len(body) > 0 && len(body) <= MaxModelDiscoveryOutputBytes && utf8.Valid(body)
}

func validModelText(value string, maximum int) bool {
	if len(value) == 0 || len(value) > maximum || !utf8.ValidString(value) {
		return false
	}
	for _, runeValue := range value {
		if unicode.IsControl(runeValue) {
			return false
		}
	}
	return true
}
