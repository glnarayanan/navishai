package adapters

import (
	"bytes"
	"strings"
	"testing"
)

func TestValidateModelOptionsRejectsUnsafeOrAmbiguousOptions(t *testing.T) {
	tests := []struct {
		name    string
		options []ModelOption
	}{
		{name: "empty", options: nil},
		{name: "empty id", options: []ModelOption{{Label: "GPT"}}},
		{name: "empty label", options: []ModelOption{{ID: "gpt", Label: ""}}},
		{name: "control id", options: []ModelOption{{ID: "gpt\n", Label: "GPT"}}},
		{name: "control label", options: []ModelOption{{ID: "gpt", Label: "GPT\x00"}}},
		{name: "duplicate id", options: []ModelOption{{ID: "gpt", Label: "GPT"}, {ID: "gpt", Label: "GPT again"}}},
		{name: "multiple defaults", options: []ModelOption{{ID: "gpt-one", Label: "One", Default: true}, {ID: "gpt-two", Label: "Two", Default: true}}},
		{name: "oversized id", options: []ModelOption{{ID: strings.Repeat("x", MaxModelIDBytes+1), Label: "X"}}},
		{name: "oversized label", options: []ModelOption{{ID: "gpt", Label: strings.Repeat("x", MaxModelLabelBytes+1)}}},
		{name: "invalid utf8", options: []ModelOption{{ID: string([]byte{'g', 'p', 't', 0xff}), Label: "GPT"}}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if err := ValidateModelOptions(test.options); err != ErrInvalidModelDiscovery {
				t.Fatalf("expected invalid model discovery, got %v", err)
			}
		})
	}
}

func TestParseModelLinesBoundsAndControls(t *testing.T) {
	valid, err := ParseModelLines([]byte("gpt-5.6-sol\ngpt-5.5\n"))
	if err != nil || len(valid) != 2 || valid[0] != (ModelOption{ID: "gpt-5.6-sol", Label: "gpt-5.6-sol"}) {
		t.Fatalf("unexpected model-line parse: %#v %v", valid, err)
	}
	for _, test := range []struct {
		name string
		body []byte
	}{
		{name: "empty", body: nil},
		{name: "invalid utf8", body: []byte{'g', 'p', 't', 0xff}},
		{name: "control", body: []byte("gpt-5.6\x00\n")},
		{name: "oversized output", body: bytes.Repeat([]byte{'x'}, MaxModelDiscoveryOutputBytes+1)},
		{name: "oversized line", body: []byte(strings.Repeat("x", MaxModelDiscoveryLineBytes+1))},
		{name: "too many lines", body: []byte(strings.Repeat("gpt\n", MaxModelDiscoveryLines+1))},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := ParseModelLines(test.body); err != ErrInvalidModelDiscovery {
				t.Fatalf("expected invalid model discovery, got %v", err)
			}
		})
	}
}
