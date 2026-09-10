package documents

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"mime"
	"net/http"
	"regexp"
	"strconv"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

const Path = "/v1/documents/extract"
const MaxBody = 7 * 1024 * 1024

var uuidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
var digestPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type Extractor interface {
	Extract(context.Context, []byte) ([]byte, error)
}
type Handler struct {
	secret    []byte
	extractor Extractor
	slots     chan struct{}
	now       func() time.Time
}
type Request struct {
	ProtocolVersion string `json:"protocol_version"`
	WorkspaceKey    string `json:"workspace_key"`
	ContentSHA256   string `json:"content_sha256"`
	Format          string `json:"format"`
	ContentBase64   string `json:"content_base64"`
}

func NewHandler(secret []byte, extractor Extractor) (*Handler, error) {
	if protocol.ValidateSecret(secret) != nil {
		return nil, ErrUnavailable
	}
	return &Handler{secret: bytes.Clone(secret), extractor: extractor, slots: make(chan struct{}, 2), now: time.Now}, nil
}

func (handler *Handler) ServeHTTP(response http.ResponseWriter, request *http.Request) {
	response.Header().Set("Content-Type", "application/json")
	response.Header().Set("Cache-Control", "no-store")
	timestamp := request.Header.Get("X-NavishAI-Timestamp")
	unix, err := strconv.ParseInt(timestamp, 10, 64)
	skew := handler.now().Sub(time.Unix(unix, 0))
	signature := request.Header.Get("X-NavishAI-Signature")
	if err != nil || skew > protocol.MaximumSkew || skew < -protocol.MaximumSkew || request.Method != "POST" || request.URL.Path != Path || !digestPattern.MatchString(signature) {
		handler.fail(response, 401, "authentication_failed")
		return
	}
	media, _, err := mime.ParseMediaType(request.Header.Get("Content-Type"))
	if err != nil || media != "application/json" {
		handler.fail(response, 415, "unsupported_media_type")
		return
	}
	body, err := io.ReadAll(io.LimitReader(request.Body, MaxBody+1))
	if err != nil || len(body) > MaxBody {
		handler.fail(response, 413, "request_too_large")
		return
	}
	if !protocol.Verify(handler.secret, timestamp, request.Method, request.URL.Path, body, signature) {
		handler.fail(response, 401, "authentication_failed")
		return
	}
	var input Request
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || decoder.Decode(&struct{}{}) != io.EOF || input.ProtocolVersion != "v1" || !uuidPattern.MatchString(input.WorkspaceKey) || !digestPattern.MatchString(input.ContentSHA256) || input.Format != "doc" || len(input.ContentBase64) > base64.StdEncoding.EncodedLen(MaxInput) {
		handler.fail(response, 422, "invalid_document")
		return
	}
	content, err := base64.StdEncoding.Strict().DecodeString(input.ContentBase64)
	digest := sha256.Sum256(content)
	if err != nil || base64.StdEncoding.EncodeToString(content) != input.ContentBase64 || len(content) > MaxInput || !bytes.HasPrefix(content, compoundSignature) || hex.EncodeToString(digest[:]) != input.ContentSHA256 {
		handler.fail(response, 422, "invalid_document")
		return
	}
	if handler.extractor == nil {
		handler.fail(response, 503, "document_converter_unavailable")
		return
	}
	select {
	case handler.slots <- struct{}{}:
		defer func() { <-handler.slots }()
	default:
		handler.fail(response, 503, "document_converter_busy")
		return
	}
	text, err := handler.extractor.Extract(request.Context(), content)
	if err != nil {
		if err == ErrUnavailable {
			handler.fail(response, 503, "document_converter_unavailable")
		} else {
			handler.fail(response, 422, "document_conversion_failed")
		}
		return
	}
	_ = json.NewEncoder(response).Encode(map[string]string{"protocol_version": "v1", "workspace_key": input.WorkspaceKey, "content_sha256": input.ContentSHA256, "format": "doc", "converter": "libreoffice", "text_base64": base64.StdEncoding.EncodeToString(text)})
}
func (handler *Handler) fail(response http.ResponseWriter, status int, code string) {
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(protocol.ErrorResponse{ProtocolVersion: "v1", Error: protocol.ProtocolError{Code: code, Message: "Document extraction could not be completed."}})
}
