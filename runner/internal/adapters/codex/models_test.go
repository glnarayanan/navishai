package codex

import (
	"reflect"
	"testing"

	"github.com/glnarayanan/navishai/runner/internal/adapters"
)

func TestModelDiscoveryParsesVisibleCodexDebugModels(t *testing.T) {
	spec := ModelDiscovery()
	if !reflect.DeepEqual(spec.Arguments, []string{"debug", "models"}) {
		t.Fatalf("unexpected Codex discovery arguments: %#v", spec.Arguments)
	}
	models, err := spec.Parse([]byte(`{"models":[
		{"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","visibility":"list","default":true},
		{"slug":"codex-auto-review","display_name":"Codex Auto Review","visibility":"hide"},
		{"slug":"gpt-5.5","display_name":"GPT-5.5","visibility":"list"}
	]}`))
	if err != nil {
		t.Fatal(err)
	}
	expected := []adapters.ModelOption{
		{ID: "gpt-5.6-sol", Label: "GPT-5.6-Sol", Default: true},
		{ID: "gpt-5.5", Label: "GPT-5.5"},
	}
	if !reflect.DeepEqual(models, expected) {
		t.Fatalf("unexpected visible Codex models: %#v", models)
	}
}

func TestModelDiscoveryRejectsMalformedCodexVisibility(t *testing.T) {
	for _, body := range []string{
		`{"models":[{"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol"}]}`,
		`{"models":[{"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","visibility":"unexpected"}]}`,
		`[{"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","visibility":"list"}]`,
	} {
		if _, err := ModelDiscovery().Parse([]byte(body)); err != adapters.ErrInvalidModelDiscovery {
			t.Fatalf("expected malformed Codex model catalog to fail, body=%s err=%v", body, err)
		}
	}
}
