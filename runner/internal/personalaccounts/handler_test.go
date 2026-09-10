package personalaccounts

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
)

func TestHandlerAuthenticatesAndGatesPersonalAccounts(t *testing.T) {
	store, err := OpenStore(privateRoot(t), func(context.Context, string, func(Challenge) error) error { return ErrUnavailable }, func(context.Context, Account, string) (runtimecatalog.Installation, TestEvidence, error) {
		return runtimecatalog.Installation{}, TestEvidence{}, ErrUnavailable
	})
	if err != nil {
		t.Fatal(err)
	}
	secret := []byte("01234567890123456789012345678901")
	handler, err := NewHandler(secret, store, func(string) bool { return false })
	if err != nil {
		t.Fatal(err)
	}
	for _, scenario := range []struct {
		path   string
		signed bool
		want   int
	}{
		{"start", false, 401}, {"start", true, 503}, {"status", true, 503}, {"disconnect", true, 200}, {"unknown", true, 404},
	} {
		body, _ := json.Marshal(map[string]any{"protocol_version": protocol.Version, "workspace_key": testOwner.WorkspaceKey, "membership_id": testOwner.MembershipID, "account_key": testKey})
		path := PathPrefix + scenario.path
		request := httptest.NewRequest("POST", path, bytes.NewReader(body))
		request.Header.Set("Content-Type", "application/json")
		if scenario.signed {
			timestamp := strconv.FormatInt(time.Now().Unix(), 10)
			signature, _ := protocol.Sign(secret, timestamp, "POST", path, body)
			request.Header.Set("X-NavishAI-Timestamp", timestamp)
			request.Header.Set("X-NavishAI-Signature", signature)
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != scenario.want {
			t.Fatalf("%s: got %d want %d", scenario.path, response.Code, scenario.want)
		}
		if response.Header().Get("Cache-Control") != "no-store" {
			t.Fatal("personal response cacheable")
		}
	}
}
