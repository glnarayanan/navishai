package runtimecatalog

import (
	"encoding/json"
	"mime"
	"net/http"
	"regexp"
	"strconv"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

const DetectionPath = "/v1/runtimes/detect"

var workspaceKeyPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

type Handler struct {
	secret  []byte
	catalog *Catalog
	now     func() time.Time
}

func NewHandler(secret []byte, catalog *Catalog, now func() time.Time) (*Handler, error) {
	if err := protocol.ValidateSecret(secret); err != nil {
		return nil, err
	}
	if catalog == nil {
		catalog = Empty()
	}
	if now == nil {
		now = time.Now
	}
	return &Handler{secret: secret, catalog: catalog, now: now}, nil
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
		handler.writeError(response, http.StatusUnsupportedMediaType, "unsupported_media_type", "Runtime detection requests must use application/json.")
		return
	}
	var input map[string]any
	if json.Unmarshal(body, &input) != nil || len(input) != 2 || input["protocol_version"] != protocol.Version ||
		!workspaceKeyPattern.MatchString(stringValue(input["workspace_key"])) {
		handler.writeError(response, http.StatusUnprocessableEntity, "invalid_request", "Runtime detection request does not match protocol v1.")
		return
	}
	_ = json.NewEncoder(response).Encode(map[string]any{
		"protocol_version": protocol.Version,
		"installations":    handler.catalog.Detect(request.Context()),
	})
}

func stringValue(value any) string {
	result, _ := value.(string)
	return result
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
