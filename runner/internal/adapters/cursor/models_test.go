package cursor

import (
	"reflect"
	"testing"

	"github.com/glnarayanan/navishai/runner/internal/adapters"
)

func TestModelDiscoveryParsesCursorListModelsOutput(t *testing.T) {
	spec := ModelDiscovery()
	if !reflect.DeepEqual(spec.Arguments, []string{"--list-models"}) {
		t.Fatalf("unexpected Cursor discovery arguments: %#v", spec.Arguments)
	}
	models, err := spec.Parse([]byte("gpt-5.5-medium\ncomposer-2.5\n"))
	if err != nil {
		t.Fatal(err)
	}
	expected := []adapters.ModelOption{
		{ID: "gpt-5.5-medium", Label: "gpt-5.5-medium"},
		{ID: "composer-2.5", Label: "composer-2.5"},
	}
	if !reflect.DeepEqual(models, expected) {
		t.Fatalf("unexpected Cursor models: %#v", models)
	}
}

func TestModelDiscoveryRejectsCursorDecoratedListOutput(t *testing.T) {
	if _, err := ModelDiscovery().Parse([]byte("gpt-5.5-medium - GPT-5.5 Medium (default)\n")); err != adapters.ErrInvalidModelDiscovery {
		t.Fatal("Cursor parser accepted an unproven decorated model-list format")
	}
}
