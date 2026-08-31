package providerconfig

import "regexp"

const (
	CodexAdapterKey  = "codex_subscription"
	ClaudeAdapterKey = "claude_subscription"
	GrokAdapterKey   = "grok_acp_subscription"
	CursorAdapterKey = "cursor_acp_subscription"
)

var uuidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
var digestPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type Definition struct {
	AdapterKey    string
	Name          string
	Description   string
	AuthModes     []string
	ModelRequired bool
	CredentialEnv string
}

var definitions = map[string]Definition{
	CodexAdapterKey: {
		AdapterKey: CodexAdapterKey, Name: "Codex", Description: "Run OpenAI Codex with a ChatGPT subscription or OpenAI API key.",
		AuthModes: []string{"api_key", "subscription"}, CredentialEnv: "OPENAI_API_KEY",
	},
	ClaudeAdapterKey: {
		AdapterKey: ClaudeAdapterKey, Name: "Claude", Description: "Run Claude Code with an eligible subscription or Anthropic API key.",
		AuthModes: []string{"api_key", "subscription"}, ModelRequired: true, CredentialEnv: "ANTHROPIC_API_KEY",
	},
	GrokAdapterKey: {
		AdapterKey: GrokAdapterKey, Name: "Grok", Description: "Run Grok through ACP with a Grok subscription.",
		AuthModes: []string{"subscription"}, ModelRequired: true,
	},
	CursorAdapterKey: {
		AdapterKey: CursorAdapterKey, Name: "Cursor", Description: "Run Cursor through ACP with a Cursor subscription.",
		AuthModes: []string{"subscription"},
	},
}

func Definitions() []Definition {
	order := []string{CodexAdapterKey, ClaudeAdapterKey, GrokAdapterKey, CursorAdapterKey}
	result := make([]Definition, 0, len(order))
	for _, key := range order {
		definition := definitions[key]
		definition.AuthModes = append([]string(nil), definition.AuthModes...)
		result = append(result, definition)
	}
	return result
}

func Lookup(adapterKey string) (Definition, bool) {
	definition, ok := definitions[adapterKey]
	if ok {
		definition.AuthModes = append([]string(nil), definition.AuthModes...)
	}
	return definition, ok
}

func validUUID(value string) bool { return uuidPattern.MatchString(value) }
