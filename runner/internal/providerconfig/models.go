package providerconfig

import (
	"net/http"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	ModelsPath = "/v1/providers/models"

	ModelDiscoveryAvailable   = "available"
	ModelDiscoveryUnsupported = "unsupported"
	ModelDiscoveryFailed      = "failed"
	maxModelOptions           = 100
	maxModelIDBytes           = 200
	maxModelLabelBytes        = 200
)

type ModelOption struct {
	ID      string `json:"id"`
	Label   string `json:"label"`
	Default bool   `json:"default"`
}

type ModelDiscovery struct {
	Status string
	Models []ModelOption
}

type ModelDiscoverySource interface {
	DiscoverModels(request *http.Request, workspaceKey, adapterKey string) ModelDiscovery
}

func validModelDiscovery(result ModelDiscovery) bool {
	switch result.Status {
	case ModelDiscoveryAvailable:
		if len(result.Models) == 0 || len(result.Models) > maxModelOptions {
			return false
		}
	case ModelDiscoveryUnsupported, ModelDiscoveryFailed:
		return len(result.Models) == 0
	default:
		return false
	}
	seen := make(map[string]struct{}, len(result.Models))
	defaults := 0
	for _, model := range result.Models {
		if !validModelText(model.ID, maxModelIDBytes) || strings.TrimSpace(model.ID) != model.ID ||
			!validModelText(model.Label, maxModelLabelBytes) || strings.TrimSpace(model.Label) != model.Label {
			return false
		}
		if _, exists := seen[model.ID]; exists {
			return false
		}
		seen[model.ID] = struct{}{}
		if model.Default {
			defaults++
		}
	}
	return defaults <= 1
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
