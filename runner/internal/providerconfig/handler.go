package providerconfig

import (
	"encoding/json"
	"errors"
	"mime"
	"net/http"
	"slices"
	"sort"
	"strconv"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

const (
	CatalogPath   = "/v1/providers/catalog"
	ConfigurePath = "/v1/providers/configure"
	RemovePath    = "/v1/providers/remove"
	PurgePath     = "/v1/providers/purge-workspace"
)

type Availability struct {
	HealthStatus            string
	Available               bool
	ExecutableVersion       string
	SupportedExecutionModes []string
	UnavailableReason       string
}

type StatusSource interface {
	ProviderAvailability(request *http.Request, workspaceKey, adapterKey string) Availability
}

type Provider struct {
	AdapterKey              string   `json:"adapter_key"`
	Name                    string   `json:"name"`
	Description             string   `json:"description"`
	AuthModes               []string `json:"auth_modes"`
	SupportedExecutionModes []string `json:"supported_execution_modes"`
	ModelRequired           bool     `json:"model_required"`
	Configured              bool     `json:"configured"`
	SecretConfigured        bool     `json:"secret_configured"`
	AuthMode                string   `json:"auth_mode"`
	ExecutionMode           string   `json:"execution_mode"`
	Model                   string   `json:"model"`
	HealthStatus            string   `json:"health_status"`
	Available               bool     `json:"available"`
	UnavailableReason       string   `json:"unavailable_reason"`
	ExecutableVersion       string   `json:"executable_version"`
}

type Handler struct {
	secret    []byte
	store     *Store
	status    StatusSource
	discovery ModelDiscoverySource
	now       func() time.Time
}

func NewHandler(secret []byte, store *Store, status StatusSource, now func() time.Time) (*Handler, error) {
	return NewHandlerWithDiscovery(secret, store, status, unavailableModelDiscovery{}, now)
}

func NewHandlerWithDiscovery(secret []byte, store *Store, status StatusSource, discovery ModelDiscoverySource, now func() time.Time) (*Handler, error) {
	if protocol.ValidateSecret(secret) != nil || store == nil || status == nil {
		return nil, errors.New("provider handler configuration is invalid")
	}
	if discovery == nil {
		discovery = unavailableModelDiscovery{}
	}
	if now == nil {
		now = time.Now
	}
	return &Handler{secret: append([]byte(nil), secret...), store: store, status: status, discovery: discovery, now: now}, nil
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
		handler.writeError(response, http.StatusUnsupportedMediaType, "unsupported_media_type", "Provider requests must use application/json.")
		return
	}
	var input map[string]any
	if json.Unmarshal(body, &input) != nil {
		handler.invalid(response)
		return
	}
	switch request.URL.Path {
	case CatalogPath:
		handler.catalog(response, request, input)
	case ConfigurePath:
		handler.configure(response, request, input, protocol.Digest(body))
	case ModelsPath:
		handler.models(response, request, input)
	case RemovePath:
		handler.remove(response, request, input, protocol.Digest(body))
	case PurgePath:
		handler.purge(response, input, protocol.Digest(body))
	default:
		handler.writeError(response, http.StatusNotFound, "not_found", "Provider endpoint was not found.")
	}
}

func (handler *Handler) models(response http.ResponseWriter, request *http.Request, input map[string]any) {
	if len(input) != 4 || input["protocol_version"] != protocol.Version || !validUUID(stringValue(input["workspace_key"])) ||
		!validKnownExecutionMode(stringValue(input["execution_mode"])) {
		handler.invalid(response)
		return
	}
	workspaceKey := stringValue(input["workspace_key"])
	adapterKey := stringValue(input["adapter_key"])
	executionMode := stringValue(input["execution_mode"])
	if !validAdapterKey(adapterKey) {
		handler.invalid(response)
		return
	}
	result := ModelDiscovery{Status: ModelDiscoveryUnsupported}
	if _, ok := Lookup(adapterKey); ok {
		connection, configured := handler.store.Get(workspaceKey, adapterKey)
		if !configured || connection.ExecutionMode != executionMode {
			handler.writeError(response, http.StatusConflict, "provider_configuration_changed", "Provider configuration changed. Find providers again before discovering models.")
			return
		}
		result = handler.discovery.DiscoverModels(request, workspaceKey, adapterKey, executionMode)
	}
	if !validModelDiscovery(result) {
		result = ModelDiscovery{Status: ModelDiscoveryFailed}
	}
	models := result.Models
	if models == nil {
		models = []ModelOption{}
	}
	_ = json.NewEncoder(response).Encode(struct {
		ProtocolVersion string        `json:"protocol_version"`
		WorkspaceKey    string        `json:"workspace_key"`
		AdapterKey      string        `json:"adapter_key"`
		ExecutionMode   string        `json:"execution_mode"`
		Status          string        `json:"status"`
		CheckedAt       string        `json:"checked_at"`
		Models          []ModelOption `json:"models"`
	}{protocol.Version, workspaceKey, adapterKey, executionMode, result.Status, handler.now().UTC().Format(time.RFC3339Nano), models})
}

func (handler *Handler) catalog(response http.ResponseWriter, request *http.Request, input map[string]any) {
	if len(input) != 2 || input["protocol_version"] != protocol.Version || !validUUID(stringValue(input["workspace_key"])) {
		handler.invalid(response)
		return
	}
	workspaceKey := stringValue(input["workspace_key"])
	providers := make([]Provider, 0, len(definitions))
	for _, definition := range Definitions() {
		providers = append(providers, handler.provider(request, workspaceKey, definition.AdapterKey))
	}
	_ = json.NewEncoder(response).Encode(struct {
		ProtocolVersion string     `json:"protocol_version"`
		WorkspaceKey    string     `json:"workspace_key"`
		Providers       []Provider `json:"providers"`
	}{protocol.Version, workspaceKey, providers})
}

func (handler *Handler) configure(response http.ResponseWriter, request *http.Request, input map[string]any, digest string) {
	if !hasExactFields(input, "protocol_version", "workspace_key", "request_id", "adapter_key", "auth_mode", "execution_mode", "model", "api_key") ||
		input["protocol_version"] != protocol.Version || !validUUID(stringValue(input["workspace_key"])) ||
		!validUUID(stringValue(input["request_id"])) || !validAdapterKey(stringValue(input["adapter_key"])) ||
		!validKnownExecutionMode(stringValue(input["execution_mode"])) {
		handler.invalid(response)
		return
	}
	workspaceKey := stringValue(input["workspace_key"])
	adapterKey := stringValue(input["adapter_key"])
	executionMode := stringValue(input["execution_mode"])
	availability := handler.status.ProviderAvailability(request, workspaceKey, adapterKey)
	if !slices.Contains(availability.SupportedExecutionModes, executionMode) {
		handler.writeError(response, http.StatusUnprocessableEntity, "execution_mode_unavailable", "The requested provider execution mode is not available in this runner deployment.")
		return
	}
	_, replay, err := handler.store.ConfigureRequest(
		stringValue(input["request_id"]), digest, workspaceKey, adapterKey,
		stringValue(input["auth_mode"]), executionMode,
		stringValue(input["model"]), stringValue(input["api_key"]),
	)
	if err != nil {
		status := http.StatusUnprocessableEntity
		code := "invalid_request"
		message := "Provider configuration is invalid."
		if errors.Is(err, ErrRequestConflict) {
			status, code, message = http.StatusConflict, "provider_request_conflict", "Provider request ID was reused with different input."
		} else if !errors.Is(err, ErrInvalidConnection) {
			status, code, message = http.StatusServiceUnavailable, "provider_state_unavailable", "Provider configuration could not be saved."
		}
		handler.writeError(response, status, code, message)
		return
	}
	if replay {
		response.Header().Set("X-NavishAI-Idempotent-Replay", "true")
	}
	handler.writeProvider(response, request, workspaceKey, adapterKey)
}

func (handler *Handler) remove(response http.ResponseWriter, request *http.Request, input map[string]any, digest string) {
	if len(input) != 4 || input["protocol_version"] != protocol.Version || !validUUID(stringValue(input["workspace_key"])) ||
		!validUUID(stringValue(input["request_id"])) {
		handler.invalid(response)
		return
	}
	workspaceKey := stringValue(input["workspace_key"])
	adapterKey := stringValue(input["adapter_key"])
	replay, err := handler.store.RemoveRequest(stringValue(input["request_id"]), digest, workspaceKey, adapterKey)
	if err != nil {
		if errors.Is(err, ErrInvalidConnection) {
			handler.invalid(response)
			return
		}
		if errors.Is(err, ErrRequestConflict) {
			handler.writeError(response, http.StatusConflict, "provider_request_conflict", "Provider request ID was reused with different input.")
			return
		}
		handler.writeError(response, http.StatusServiceUnavailable, "provider_state_unavailable", "Provider configuration could not be removed.")
		return
	}
	if replay {
		response.Header().Set("X-NavishAI-Idempotent-Replay", "true")
	}
	handler.writeProvider(response, request, workspaceKey, adapterKey)
}

func (handler *Handler) purge(response http.ResponseWriter, input map[string]any, digest string) {
	if len(input) != 3 || input["protocol_version"] != protocol.Version || !validUUID(stringValue(input["workspace_key"])) ||
		!validUUID(stringValue(input["request_id"])) {
		handler.invalid(response)
		return
	}
	workspaceKey := stringValue(input["workspace_key"])
	if err := handler.store.PurgeWorkspaceRequest(stringValue(input["request_id"]), digest, workspaceKey); err != nil {
		if errors.Is(err, ErrInvalidConnection) {
			handler.invalid(response)
			return
		}
		handler.writeError(response, http.StatusServiceUnavailable, "provider_state_unavailable", "Provider configuration could not be purged.")
		return
	}
	_ = json.NewEncoder(response).Encode(struct {
		ProtocolVersion string `json:"protocol_version"`
		WorkspaceKey    string `json:"workspace_key"`
		Purged          bool   `json:"purged"`
	}{protocol.Version, workspaceKey, true})
}

func (handler *Handler) writeProvider(response http.ResponseWriter, request *http.Request, workspaceKey, adapterKey string) {
	_ = json.NewEncoder(response).Encode(struct {
		ProtocolVersion string   `json:"protocol_version"`
		WorkspaceKey    string   `json:"workspace_key"`
		Provider        Provider `json:"provider"`
	}{protocol.Version, workspaceKey, handler.provider(request, workspaceKey, adapterKey)})
}

func (handler *Handler) provider(request *http.Request, workspaceKey, adapterKey string) Provider {
	definition, _ := Lookup(adapterKey)
	connection, configured := handler.store.Get(workspaceKey, adapterKey)
	availability := handler.status.ProviderAvailability(request, workspaceKey, adapterKey)
	incompleteModel := configured && definition.RequiresModel(connection.AuthMode) && connection.Model == ""
	supportedModes := append([]string(nil), definition.SupportedExecutionModes...)
	if availability.SupportedExecutionModes != nil {
		supportedModes = append([]string(nil), availability.SupportedExecutionModes...)
	}
	sort.Strings(supportedModes)
	selectedMode := ""
	if configured {
		selectedMode = connection.ExecutionMode
	}
	health := availability.HealthStatus
	if !configured {
		health = "not_configured"
	} else if selectedMode == protocol.ExecutionModeLegacyUnknown || selectedMode == "" {
		health = "unavailable"
	} else if !slices.Contains(supportedModes, selectedMode) {
		health = "unavailable"
	} else if incompleteModel {
		health = "unavailable"
	} else if health == "" {
		health = "unavailable"
	}
	available := configured && !incompleteModel && availability.Available && health == "available" && slices.Contains(supportedModes, selectedMode)
	reason := availability.UnavailableReason
	if incompleteModel {
		reason = "Choose a model before testing or running this provider."
	} else if configured && selectedMode == protocol.ExecutionModeLegacyUnknown {
		reason = "Execution mode must be selected again for this provider."
	} else if configured && selectedMode == "" {
		reason = "Execution mode is missing; configure this provider again."
	} else if configured && !slices.Contains(supportedModes, selectedMode) {
		reason = "The selected execution mode is not supported by this runner deployment."
	} else if configured && !available && reason == "" {
		reason = "The selected execution mode is unavailable in this runner deployment."
	}
	return Provider{
		AdapterKey: definition.AdapterKey, Name: definition.Name, Description: definition.Description,
		AuthModes: definition.AuthModes, SupportedExecutionModes: supportedModes, ModelRequired: definition.ModelRequired,
		Configured: configured, SecretConfigured: configured && connection.APIKey != "", AuthMode: connection.AuthMode,
		ExecutionMode: selectedMode, Model: connection.Model, HealthStatus: health, Available: available,
		UnavailableReason: reason, ExecutableVersion: availability.ExecutableVersion,
	}
}

func (handler *Handler) invalid(response http.ResponseWriter) {
	handler.writeError(response, http.StatusUnprocessableEntity, "invalid_request", "Provider request does not match protocol v1.")
}

func hasExactFields(input map[string]any, fields ...string) bool {
	if len(input) != len(fields) {
		return false
	}
	expected := make(map[string]struct{}, len(fields))
	for _, field := range fields {
		expected[field] = struct{}{}
	}
	for field := range input {
		if _, ok := expected[field]; !ok {
			return false
		}
	}
	return true
}

func (handler *Handler) writeError(response http.ResponseWriter, status int, code, message string) {
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(protocol.ErrorResponse{
		ProtocolVersion: protocol.Version,
		Error:           protocol.ProtocolError{Code: code, Message: message},
	})
}

type unavailableModelDiscovery struct{}

func (unavailableModelDiscovery) DiscoverModels(*http.Request, string, string, string) ModelDiscovery {
	return ModelDiscovery{Status: ModelDiscoveryUnsupported}
}

func stringValue(value any) string {
	result, _ := value.(string)
	return result
}

func absoluteDuration(value time.Duration) time.Duration {
	if value < 0 {
		return -value
	}
	return value
}
