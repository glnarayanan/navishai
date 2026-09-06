package main

import (
	"strings"
	"testing"
)

func TestConfigureSearchProviderSelectsBoundedAdapters(t *testing.T) {
	env := func(values map[string]string) func(string) string {
		return func(key string) string { return values[key] }
	}
	if provider, err := configureSearchProvider(env(nil)); provider != nil || err != nil {
		t.Fatalf("expected no provider without configuration, got %v %v", provider, err)
	}
	for name, values := range map[string]map[string]string{
		"searxng": {"NAVISHAI_WEB_SEARCH_PROVIDER": "searxng", "NAVISHAI_SEARXNG_URL": "https://search.example.internal"},
		"exa":     {"NAVISHAI_WEB_SEARCH_PROVIDER": "exa", "NAVISHAI_EXA_API_KEY": "exa-key"},
		"tavily":  {"NAVISHAI_WEB_SEARCH_PROVIDER": "tavily", "NAVISHAI_TAVILY_API_KEY": "tvly-key"},
	} {
		provider, err := configureSearchProvider(env(values))
		if err != nil || provider == nil || provider.Key() != name {
			t.Fatalf("%s: provider=%v err=%v", name, provider, err)
		}
	}
	for name, values := range map[string]map[string]string{
		"unknown":       {"NAVISHAI_WEB_SEARCH_PROVIDER": "bing"},
		"missing key":   {"NAVISHAI_WEB_SEARCH_PROVIDER": "exa"},
		"cleartext url": {"NAVISHAI_WEB_SEARCH_PROVIDER": "tavily", "NAVISHAI_TAVILY_API_KEY": "k", "NAVISHAI_TAVILY_URL": "http://tavily.example.com/"},
	} {
		if _, err := configureSearchProvider(env(values)); err == nil || strings.TrimSpace(err.Error()) == "" {
			t.Fatalf("%s: expected a configuration error", name)
		}
	}
}
