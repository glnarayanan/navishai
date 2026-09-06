package personalaccounts

import (
	"bytes"
	"encoding/json"
	"io"
	"mime"
	"net/http"
	"strconv"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

const PathPrefix = "/v1/personal-accounts/"

type Handler struct {
	secret  []byte
	store   *Store
	enabled func(string) bool
	now     func() time.Time
}

func NewHandler(secret []byte, store *Store, enabled func(string) bool) (*Handler, error) {
	if protocol.ValidateSecret(secret) != nil || store == nil || enabled == nil {
		return nil, ErrUnavailable
	}
	return &Handler{secret: append([]byte(nil), secret...), store: store, enabled: enabled, now: time.Now}, nil
}

func (handler *Handler) ServeHTTP(response http.ResponseWriter, request *http.Request) {
	response.Header().Set("Content-Type", "application/json")
	response.Header().Set("Cache-Control", "no-store")
	body, err := protocol.ReadBody(request.Body)
	if err != nil {
		handler.fail(response, 413, "request_too_large")
		return
	}
	timestamp := request.Header.Get("X-NavishAI-Timestamp")
	unix, err := strconv.ParseInt(timestamp, 10, 64)
	skew := handler.now().Sub(time.Unix(unix, 0))
	if err != nil || skew > protocol.MaximumSkew || skew < -protocol.MaximumSkew || request.Method != "POST" || !protocol.Verify(handler.secret, timestamp, request.Method, request.URL.Path, body, request.Header.Get("X-NavishAI-Signature")) {
		handler.fail(response, 401, "authentication_failed")
		return
	}
	media, _, err := mime.ParseMediaType(request.Header.Get("Content-Type"))
	if err != nil || media != "application/json" {
		handler.fail(response, 415, "unsupported_media_type")
		return
	}
	var input struct {
		ProtocolVersion string `json:"protocol_version"`
		WorkspaceKey    string `json:"workspace_key"`
		MembershipID    int64  `json:"membership_id"`
		AccountKey      string `json:"account_key"`
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || decoder.Decode(&struct{}{}) != io.EOF || input.ProtocolVersion != protocol.Version || !uuidPattern.MatchString(input.WorkspaceKey) {
		handler.fail(response, 422, "invalid_request")
		return
	}
	if request.URL.Path == PathPrefix+"purge-workspace" {
		if input.MembershipID != 0 || input.AccountKey != "" {
			handler.fail(response, 422, "invalid_request")
			return
		}
		if err := handler.store.PurgeWorkspace(input.WorkspaceKey); err != nil {
			handler.fail(response, 409, "personal_account_conflict")
			return
		}
		_ = json.NewEncoder(response).Encode(map[string]any{"protocol_version": protocol.Version, "workspace_key": input.WorkspaceKey, "purged": true})
		return
	}
	if !validOwner(Owner{input.WorkspaceKey, input.MembershipID}) || !uuidPattern.MatchString(input.AccountKey) {
		handler.fail(response, 422, "invalid_request")
		return
	}
	owner := Owner{input.WorkspaceKey, input.MembershipID}
	var account Account
	switch request.URL.Path {
	case PathPrefix + "start":
		if !handler.enabled(input.WorkspaceKey) {
			handler.fail(response, 503, "personal_account_unavailable")
			return
		}
		account, err = handler.store.Start(owner, input.AccountKey)
	case PathPrefix + "status":
		if !handler.enabled(input.WorkspaceKey) {
			handler.fail(response, 503, "personal_account_unavailable")
			return
		}
		account, err = handler.store.Status(owner, input.AccountKey)
	case PathPrefix + "disconnect":
		account, err = handler.store.Disconnect(owner, input.AccountKey)
	default:
		handler.fail(response, 404, "not_found")
		return
	}
	if err != nil {
		if err == ErrConflict {
			handler.fail(response, 409, "personal_account_conflict")
		} else {
			handler.fail(response, 503, "personal_account_unavailable")
		}
		return
	}
	_ = json.NewEncoder(response).Encode(map[string]any{"protocol_version": protocol.Version, "account": account})
}

func (handler *Handler) fail(response http.ResponseWriter, status int, code string) {
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(protocol.ErrorResponse{ProtocolVersion: protocol.Version, Error: protocol.ProtocolError{Code: code, Message: "Personal account request could not be completed."}})
}
