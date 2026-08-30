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

const (
	LegacyDetectionPath = "/v1/runtimes/detect"
	DetectionPath       = "/v2/runtimes/detect"
	DetectionVersion    = "v2"
)

var workspaceKeyPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

type Handler struct {
	secret                       []byte
	catalog                      *Catalog
	now                          func() time.Time
	version                      string
	includeConfigurationIdentity bool
}

func NewHandler(secret []byte, catalog *Catalog, now func() time.Time) (*Handler, error) {
	return newHandler(secret, catalog, now, DetectionVersion, true)
}

func NewLegacyHandler(secret []byte, catalog *Catalog, now func() time.Time) (*Handler, error) {
	return newHandler(secret, catalog, now, protocol.Version, false)
}

func newHandler(secret []byte, catalog *Catalog, now func() time.Time, version string, includeConfigurationIdentity bool) (*Handler, error) {
	if err := protocol.ValidateSecret(secret); err != nil {
		return nil, err
	}
	if catalog == nil {
		catalog = Empty()
	}
	if now == nil {
		now = time.Now
	}
	return &Handler{
		secret: secret, catalog: catalog, now: now, version: version,
		includeConfigurationIdentity: includeConfigurationIdentity,
	}, nil
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
	if json.Unmarshal(body, &input) != nil || len(input) != 2 || input["protocol_version"] != handler.version ||
		!workspaceKeyPattern.MatchString(stringValue(input["workspace_key"])) {
		handler.writeError(response, http.StatusUnprocessableEntity, "invalid_request", "Runtime detection request does not match the endpoint protocol.")
		return
	}
	installations := handler.catalog.Detect(request.Context())
	var responseInstallations any = installations
	if !handler.includeConfigurationIdentity {
		responseInstallations = legacyInstallations(installations)
	}
	_ = json.NewEncoder(response).Encode(map[string]any{
		"protocol_version": handler.version,
		"installations":    responseInstallations,
	})
}

type legacyInstallation struct {
	DetectionKey          string            `json:"detection_key"`
	AdapterKey            string            `json:"adapter_key"`
	ProtocolVersion       string            `json:"protocol_version"`
	ExecutablePath        string            `json:"executable_path"`
	ExecutableVersion     string            `json:"executable_version"`
	AccountMetadata       map[string]string `json:"account_metadata"`
	Capabilities          []string          `json:"capabilities"`
	MinimumVersion        string            `json:"minimum_version"`
	MaximumVersion        string            `json:"maximum_version"`
	CompatibilityStatus   string            `json:"compatibility_status"`
	IncompatibilityReason string            `json:"incompatibility_reason"`
	HealthStatus          string            `json:"health_status"`
	CheckedAt             string            `json:"checked_at"`
}

func legacyInstallations(installations []Installation) []legacyInstallation {
	result := make([]legacyInstallation, len(installations))
	for index, installation := range installations {
		result[index] = legacyInstallation{
			DetectionKey: installation.DetectionKey, AdapterKey: installation.AdapterKey,
			ProtocolVersion: installation.ProtocolVersion, ExecutablePath: installation.ExecutablePath,
			ExecutableVersion: installation.ExecutableVersion, AccountMetadata: installation.AccountMetadata,
			Capabilities: installation.Capabilities, MinimumVersion: installation.MinimumVersion,
			MaximumVersion: installation.MaximumVersion, CompatibilityStatus: installation.CompatibilityStatus,
			IncompatibilityReason: installation.IncompatibilityReason, HealthStatus: installation.HealthStatus,
			CheckedAt: installation.CheckedAt,
		}
	}
	return result
}

func stringValue(value any) string {
	result, _ := value.(string)
	return result
}

func (handler *Handler) writeError(response http.ResponseWriter, status int, code, message string) {
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(protocol.ErrorResponse{
		ProtocolVersion: handler.version,
		Error:           protocol.ProtocolError{Code: code, Message: message},
	})
}

func absoluteDuration(value time.Duration) time.Duration {
	if value < 0 {
		return -value
	}
	return value
}
