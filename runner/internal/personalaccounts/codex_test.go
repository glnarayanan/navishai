package personalaccounts

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"strings"
	"testing"

	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

type fixtureRunner struct {
	t               *testing.T
	loginID         string
	verificationURL string
	accountType     string
	request         supervisor.Request
}

func (runner *fixtureRunner) Interact(ctx context.Context, request supervisor.Request, interact func(context.Context, io.ReadWriter) error) (supervisor.Result, error) {
	runner.request = request
	client, server := net.Pipe()
	defer client.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer server.Close()
		decoder, encoder := json.NewDecoder(server), json.NewEncoder(server)
		for {
			var message struct {
				ID     int            `json:"id"`
				Method string         `json:"method"`
				Params map[string]any `json:"params"`
			}
			if decoder.Decode(&message) != nil {
				return
			}
			var result any = map[string]any{}
			switch message.Method {
			case "initialize":
			case "initialized":
				continue
			case "account/login/start":
				if message.Params["type"] != "chatgptDeviceCode" {
					runner.t.Error("unexpected login method")
				}
				result = map[string]string{"type": "chatgptDeviceCode", "loginId": "4ee58722-70ad-4b11-89f7-23a1edc78d77", "verificationUrl": runner.verificationURL, "userCode": "ABCD-EFGH"}
			case "account/read":
				result = map[string]any{"account": map[string]string{"type": runner.accountType, "email": "private@example.com"}}
			default:
				runner.t.Errorf("unexpected RPC: %s", message.Method)
				return
			}
			if encoder.Encode(map[string]any{"id": message.ID, "result": result}) != nil {
				return
			}
			if message.Method == "account/login/start" {
				if encoder.Encode(map[string]any{"method": "account/login/completed", "params": map[string]any{"loginId": runner.loginID, "success": true}}) != nil {
					return
				}
			}
		}
	}()
	err := interact(ctx, client)
	client.Close()
	<-done
	return supervisor.Result{}, err
}

func TestCodexDeviceLoginUsesSupervisedDedicatedHome(t *testing.T) {
	runner := &fixtureRunner{t: t, loginID: "4ee58722-70ad-4b11-89f7-23a1edc78d77", verificationURL: "https://auth.openai.com/codex/device", accountType: "chatgpt"}
	driver := Codex{Runner: runner, Executable: "/approved/codex", EgressProfileKey: "codex_auth"}
	var challenge Challenge
	err := driver.Login(context.Background(), "/private/owner/home", func(value Challenge) error { challenge = value; return nil })
	if err != nil {
		t.Fatal(err)
	}
	if challenge.UserCode != "ABCD-EFGH" || runner.request.HomeDir != "/private/owner/home" || runner.request.WorkingDir != runner.request.HomeDir || runner.request.Credentials["CODEX_HOME"] != runner.request.HomeDir || len(runner.request.Credentials) != 1 || runner.request.EgressProfileKey != "codex_auth" {
		t.Fatal("login did not preserve scoped boundary")
	}
	serialized, _ := json.Marshal(challenge)
	if strings.Contains(string(serialized), "private@example.com") {
		t.Fatal("account metadata leaked")
	}
}

func TestCodexDeviceLoginRejectsUntrustedChallengesAndWrongAccounts(t *testing.T) {
	for _, scenario := range []struct{ name, url, loginID, accountType string }{
		{"untrusted URL", "https://evil.example/codex/device", "4ee58722-70ad-4b11-89f7-23a1edc78d77", "chatgpt"},
		{"credential URL", "https://auth.openai.com@evil.example/codex/device", "4ee58722-70ad-4b11-89f7-23a1edc78d77", "chatgpt"},
		{"query injection", "https://auth.openai.com/codex/device?redirect=evil", "4ee58722-70ad-4b11-89f7-23a1edc78d77", "chatgpt"},
		{"wrong completion", "https://auth.openai.com/codex/device", "9334c36b-98a9-4314-8b40-c42f5d1c16b8", "chatgpt"},
		{"API account", "https://auth.openai.com/codex/device", "4ee58722-70ad-4b11-89f7-23a1edc78d77", "apiKey"},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			runner := &fixtureRunner{t: t, loginID: scenario.loginID, verificationURL: scenario.url, accountType: scenario.accountType}
			err := (Codex{Runner: runner, Executable: "/approved/codex", EgressProfileKey: "codex_auth"}).Login(context.Background(), "/private/home", func(Challenge) error { return nil })
			if err != ErrUnavailable {
				t.Fatalf("got %v", err)
			}
		})
	}
}

func TestCodexDeviceLoginFailsClosedWithoutConfiguration(t *testing.T) {
	if err := (Codex{}).Login(context.Background(), "/private/home", func(Challenge) error { return nil }); err != ErrUnavailable {
		t.Fatal(err)
	}
}
