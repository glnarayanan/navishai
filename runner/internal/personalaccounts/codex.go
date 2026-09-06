package personalaccounts

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"regexp"

	"github.com/glnarayanan/navishai/runner/internal/adapters"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

var ErrUnavailable = errors.New("personal account sign-in is unavailable")

var deviceCodePattern = regexp.MustCompile(`^[A-Z0-9-]{4,32}$`)
var uuidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

type Challenge struct {
	LoginID         string `json:"login_id"`
	VerificationURL string `json:"verification_url"`
	UserCode        string `json:"user_code"`
}

type Codex struct {
	Runner           adapters.InteractiveProcessRunner
	Executable       string
	EgressProfileKey string
}

func (driver Codex) Login(ctx context.Context, home string, challenge func(Challenge) error) error {
	if driver.Runner == nil || driver.Executable == "" || driver.EgressProfileKey == "" || home == "" || challenge == nil {
		return ErrUnavailable
	}
	result, err := driver.Runner.Interact(ctx, supervisor.Request{
		Executable: driver.Executable,
		Arguments:  []string{"app-server", "--listen", "stdio://", "-c", `cli_auth_credentials_store="file"`},
		WorkingDir: home, HomeDir: home,
		Credentials: map[string]string{"CODEX_HOME": home}, EgressProfileKey: driver.EgressProfileKey,
	}, func(_ context.Context, stream io.ReadWriter) error {
		wire := &codexWire{scanner: bufio.NewScanner(stream), encoder: json.NewEncoder(stream)}
		wire.scanner.Buffer(make([]byte, 4096), 128*1024)
		if err := wire.call(1, "initialize", map[string]any{"clientInfo": map[string]string{"name": "navishai", "version": "1"}}, nil); err != nil {
			return err
		}
		if err := wire.encoder.Encode(map[string]any{"method": "initialized"}); err != nil {
			return ErrUnavailable
		}
		var start struct {
			Type            string `json:"type"`
			LoginID         string `json:"loginId"`
			VerificationURL string `json:"verificationUrl"`
			UserCode        string `json:"userCode"`
		}
		if err := wire.call(2, "account/login/start", map[string]string{"type": "chatgptDeviceCode"}, &start); err != nil {
			return err
		}
		if start.Type != "chatgptDeviceCode" || !uuidPattern.MatchString(start.LoginID) || !validVerificationURL(start.VerificationURL) || !deviceCodePattern.MatchString(start.UserCode) {
			return ErrUnavailable
		}
		if err := challenge(Challenge{start.LoginID, start.VerificationURL, start.UserCode}); err != nil {
			return err
		}
		for wire.scanner.Scan() {
			var event struct {
				Method string `json:"method"`
				Params struct {
					LoginID string `json:"loginId"`
					Success bool   `json:"success"`
				} `json:"params"`
			}
			if json.Unmarshal(wire.scanner.Bytes(), &event) != nil {
				return ErrUnavailable
			}
			if event.Method != "account/login/completed" {
				continue
			}
			if event.Params.LoginID != start.LoginID || !event.Params.Success {
				return ErrUnavailable
			}
			var account struct {
				Account *struct {
					Type string `json:"type"`
				} `json:"account"`
			}
			if err := wire.call(3, "account/read", map[string]bool{"refreshToken": false}, &account); err != nil || account.Account == nil || account.Account.Type != "chatgpt" {
				return ErrUnavailable
			}
			return nil
		}
		return ErrUnavailable
	})
	if err != nil || result.Canceled || result.TimedOut || result.OutputExceeded || result.ExitCode != 0 {
		return ErrUnavailable
	}
	return nil
}

type codexWire struct {
	scanner *bufio.Scanner
	encoder *json.Encoder
}

func (wire *codexWire) call(id int, method string, params any, result any) error {
	if wire.encoder.Encode(map[string]any{"id": id, "method": method, "params": params}) != nil {
		return ErrUnavailable
	}
	for wire.scanner.Scan() {
		var response struct {
			ID     *int            `json:"id"`
			Result json.RawMessage `json:"result"`
			Error  json.RawMessage `json:"error"`
		}
		if json.Unmarshal(wire.scanner.Bytes(), &response) != nil {
			return ErrUnavailable
		}
		if response.ID == nil {
			continue
		}
		if *response.ID != id || len(response.Error) != 0 || len(response.Result) == 0 {
			return ErrUnavailable
		}
		if result != nil && json.Unmarshal(response.Result, result) != nil {
			return ErrUnavailable
		}
		return nil
	}
	return ErrUnavailable
}

func validVerificationURL(value string) bool {
	parsed, err := url.Parse(value)
	return err == nil && parsed.Scheme == "https" && parsed.Host == "auth.openai.com" && parsed.Path == "/codex/device" && parsed.User == nil && parsed.RawQuery == "" && parsed.Fragment == ""
}
