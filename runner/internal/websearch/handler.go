package websearch

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"strconv"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

type Handler struct {
	secret   []byte
	provider Provider
	store    *Store
	now      func() time.Time
}

func NewHandler(secret []byte, provider Provider, store *Store, now func() time.Time) (*Handler, error) {
	if err := protocol.ValidateSecret(secret); err != nil {
		return nil, err
	}
	if store == nil {
		return nil, errors.New("web search store is required")
	}
	if now == nil {
		now = time.Now
	}
	return &Handler{secret: secret, provider: provider, store: store, now: now}, nil
}

func (handler *Handler) ServeHTTP(response http.ResponseWriter, request *http.Request) {
	response.Header().Set("Content-Type", "application/json")
	response.Header().Set("Cache-Control", "no-store")
	if request.ContentLength > protocol.MaxBodyBytes {
		handler.writeError(response, http.StatusRequestEntityTooLarge, "request_too_large", "Web search request exceeds the protocol limit.")
		return
	}
	body, err := protocol.ReadBody(request.Body)
	if err != nil {
		handler.writeError(response, http.StatusRequestEntityTooLarge, "request_too_large", "Web search request exceeds the protocol limit.")
		return
	}
	timestamp := request.Header.Get("X-NavishAI-Timestamp")
	unixTime, err := strconv.ParseInt(timestamp, 10, 64)
	if err != nil || duration(handler.now().Sub(time.Unix(unixTime, 0))) > protocol.MaximumSkew ||
		!protocol.Verify(handler.secret, timestamp, request.Method, request.URL.Path, body, request.Header.Get("X-NavishAI-Signature")) {
		handler.writeError(response, http.StatusUnauthorized, "authentication_failed", "Runner request authentication failed.")
		return
	}
	mediaType, _, err := mime.ParseMediaType(request.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		handler.writeError(response, http.StatusUnsupportedMediaType, "unsupported_media_type", "Web search requests must use application/json.")
		return
	}
	input, err := decodeRequest(body)
	if err != nil || input.Validate(protocol.Version) != nil {
		handler.writeError(response, http.StatusUnprocessableEntity, "invalid_request", "Web search request does not match protocol v1.")
		return
	}
	if handler.provider == nil {
		handler.writeError(response, http.StatusServiceUnavailable, "provider_unavailable", "No public-web search provider is configured.")
		return
	}
	result, replayed, err := handler.store.Resolve(input.RequestKey, protocol.Digest(body), func() (Response, error) {
		results, cost, err := handler.provider.Search(request.Context(), input.Query, input.MaxResults)
		if err != nil {
			return Response{}, err
		}
		results, err = Normalize(results, input.MaxResults)
		if err != nil || cost < 0 {
			return Response{}, ErrInvalidRequest
		}
		return Response{
			ProtocolVersion: protocol.Version, WorkspaceKey: input.WorkspaceKey, RequestKey: input.RequestKey,
			Query: input.Query, ProviderKey: handler.provider.Key(), PolicyDecision: "allowed", CostUnits: cost,
			RetrievedAt: handler.now().UTC(), Results: results,
		}, nil
	})
	if errors.Is(err, ErrConflict) {
		handler.writeError(response, http.StatusConflict, "idempotency_conflict", "Request key belongs to another web search.")
		return
	}
	if err != nil {
		handler.writeError(response, http.StatusServiceUnavailable, "provider_unavailable", "Public-web search is unavailable.")
		return
	}
	if replayed {
		response.Header().Set("X-NavishAI-Idempotent-Replay", "true")
	}
	_ = json.NewEncoder(response).Encode(result)
}

func decodeRequest(body []byte) (Request, error) {
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	var input Request
	if err := decoder.Decode(&input); err != nil {
		return Request{}, err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return Request{}, ErrInvalidRequest
	}
	return input, nil
}

func (handler *Handler) writeError(response http.ResponseWriter, status int, code, message string) {
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(protocol.ErrorResponse{
		ProtocolVersion: protocol.Version, Error: protocol.ProtocolError{Code: code, Message: message},
	})
}

func duration(value time.Duration) time.Duration {
	if value < 0 {
		return -value
	}
	return value
}
