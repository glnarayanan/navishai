package codex

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"

	"github.com/glnarayanan/navishai/runner/internal/adapters"
)

func ModelDiscovery() adapters.ModelDiscoverySpec {
	return adapters.ModelDiscoverySpec{
		Arguments: []string{"debug", "models"},
		Parse:     parseModelOptions,
	}
}

func parseModelOptions(body []byte) ([]adapters.ModelOption, error) {
	if err := adapters.ValidateModelDiscoveryOutput(body); err != nil {
		return nil, adapters.ErrInvalidModelDiscovery
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	var document struct {
		Models []struct {
			Slug        string `json:"slug"`
			DisplayName string `json:"display_name"`
			Visibility  string `json:"visibility"`
			Default     *bool  `json:"default"`
		} `json:"models"`
	}
	if decoder.Decode(&document) != nil || !jsonEOF(decoder) {
		return nil, adapters.ErrInvalidModelDiscovery
	}
	options := make([]adapters.ModelOption, 0, len(document.Models))
	for _, model := range document.Models {
		switch model.Visibility {
		case "list":
			option := adapters.ModelOption{ID: model.Slug, Label: model.DisplayName}
			if model.Default != nil {
				option.Default = *model.Default
			}
			options = append(options, option)
		case "hide":
			continue
		default:
			return nil, adapters.ErrInvalidModelDiscovery
		}
	}
	if err := adapters.ValidateModelOptions(options); err != nil {
		return nil, err
	}
	return options, nil
}

func jsonEOF(decoder *json.Decoder) bool {
	var extra any
	return errors.Is(decoder.Decode(&extra), io.EOF)
}
