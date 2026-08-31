package execution

import (
	"context"

	"github.com/glnarayanan/navishai/runner/internal/adapters/claude"
	"github.com/glnarayanan/navishai/runner/internal/adapters/codex"
	"github.com/glnarayanan/navishai/runner/internal/providerapi"
)

// ProviderAPI is the runner-owned seam for fixed direct provider model
// discovery.
type ProviderAPI interface {
	DiscoverModels(context.Context, string, string) ([]providerapi.ModelOption, error)
}

var _ ProviderAPI = (*providerapi.Client)(nil)

func isDirectProviderAPIAdapter(adapterKey string) bool {
	return adapterKey == codex.AdapterKey || adapterKey == claude.AdapterKey
}
