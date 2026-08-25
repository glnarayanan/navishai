package admission

import (
	"encoding/json"
	"errors"
	"mime"
	"net/http"
	"strconv"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

type Handler struct {
	secret []byte
	store  *Store
	now    func() time.Time
}

func NewHandler(secret []byte, store *Store, now func() time.Time) (*Handler, error) {
	if err := protocol.ValidateSecret(secret); err != nil {
		return nil, err
	}
	if store == nil {
		return nil, errors.New("admission store is required")
	}
	if now == nil {
		now = time.Now
	}
	return &Handler{secret: secret, store: store, now: now}, nil
}

func (handler *Handler) ServeHTTP(response http.ResponseWriter, request *http.Request) {
	response.Header().Set("Content-Type", "application/json")
	response.Header().Set("Cache-Control", "no-store")
	if request.ContentLength > protocol.MaxBodyBytes {
		handler.writeError(response, http.StatusRequestEntityTooLarge, "request_too_large", "Request body exceeds the protocol limit.")
		return
	}
	body, err := protocol.ReadBody(request.Body)
	if err != nil {
		handler.writeError(response, http.StatusRequestEntityTooLarge, "request_too_large", "Request body exceeds the protocol limit.")
		return
	}
	timestamp := request.Header.Get("X-NavishAI-Timestamp")
	unixTime, err := strconv.ParseInt(timestamp, 10, 64)
	if err != nil || absoluteDuration(handler.now().Sub(time.Unix(unixTime, 0))) > protocol.MaximumSkew ||
		!protocol.Verify(handler.secret, timestamp, request.Method, request.URL.Path, body, request.Header.Get("X-NavishAI-Signature")) {
		handler.writeError(response, http.StatusUnauthorized, "authentication_failed", "Runner request authentication failed.")
		return
	}
	mediaType, _, err := mime.ParseMediaType(request.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		handler.writeError(response, http.StatusUnsupportedMediaType, "unsupported_media_type", "Admission requests must use application/json.")
		return
	}
	admission, err := protocol.DecodeAdmissionBytes(body)
	if err != nil {
		handler.writeError(response, http.StatusUnprocessableEntity, "invalid_request", "Admission request does not match protocol v1.")
		return
	}
	acceptedAt := handler.now().UTC()
	event, err := protocol.NewCanonicalEvent(admission.RunID, 1, "run.admitted", acceptedAt, map[string]any{
		"workspace_key": admission.WorkspaceKey,
		"task_key":      admission.Task.TaskKey,
		"attempt":       admission.Task.Attempt,
	})
	if err != nil {
		handler.writeError(response, http.StatusServiceUnavailable, "admission_unavailable", "Runner cannot durably admit this request.")
		return
	}
	result := protocol.AdmissionResponse{
		ProtocolVersion: protocol.Version,
		RunID:           admission.RunID,
		Status:          "accepted",
		Event:           event,
	}
	result, replayed, err := handler.store.Admit(admission, protocol.Digest(body), result)
	if errors.Is(err, ErrConflict) {
		handler.writeError(response, http.StatusConflict, "idempotency_conflict", "Idempotency key belongs to another request.")
		return
	}
	if err != nil {
		handler.writeError(response, http.StatusServiceUnavailable, "admission_unavailable", "Runner cannot durably admit this request.")
		return
	}
	if replayed {
		response.Header().Set("X-NavishAI-Idempotent-Replay", "true")
	}
	response.WriteHeader(http.StatusAccepted)
	_ = json.NewEncoder(response).Encode(result)
}

func (handler *Handler) writeError(response http.ResponseWriter, status int, code, message string) {
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(protocol.ErrorResponse{
		ProtocolVersion: protocol.Version,
		Error:           protocol.ProtocolError{Code: code, Message: message},
	})
}

func absoluteDuration(value time.Duration) time.Duration {
	if value < 0 {
		return -value
	}
	return value
}
