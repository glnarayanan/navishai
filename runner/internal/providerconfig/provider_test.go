package providerconfig

import "testing"

func TestGrokSupportsSubscriptionAuthenticationOnly(t *testing.T) {
	definition, ok := Lookup(GrokAdapterKey)
	if !ok {
		t.Fatal("Grok provider definition is missing")
	}
	if len(definition.AuthModes) != 1 || definition.AuthModes[0] != "subscription" || definition.CredentialEnv != "" {
		t.Fatalf("Grok advertised unsupported API-key authentication: %#v", definition)
	}
}
