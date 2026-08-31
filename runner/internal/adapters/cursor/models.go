package cursor

import "github.com/glnarayanan/navishai/runner/internal/adapters"

func ModelDiscovery() adapters.ModelDiscoverySpec {
	return adapters.ModelDiscoverySpec{
		Arguments: []string{"--list-models"},
		Parse:     adapters.ParseModelLines,
	}
}
