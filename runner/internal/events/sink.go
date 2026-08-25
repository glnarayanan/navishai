package events

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

const eventPath = "/webhooks/runner-events"

var (
	ErrConfiguration = errors.New("invalid event sink configuration")
	ErrConflict      = errors.New("control plane rejected conflicting event")
	ErrRejected      = errors.New("control plane rejected event")
	ErrUnavailable   = errors.New("control plane event endpoint unavailable")
)

type Sink struct {
	endpoint *url.URL
	secret   []byte
	client   *http.Client
	now      func() time.Time
}

func New(address string, secret []byte, allowPrivateHTTP bool, now func() time.Time) (*Sink, error) {
	if err := protocol.ValidateSecret(secret); err != nil {
		return nil, ErrConfiguration
	}
	base, err := url.Parse(address)
	if err != nil || base.Hostname() == "" || base.User != nil || base.RawQuery != "" || base.Fragment != "" ||
		(base.Scheme != "http" && base.Scheme != "https") || (base.Path != "" && base.Path != "/") {
		return nil, ErrConfiguration
	}
	if base.Scheme != "https" && !isLoopback(base.Hostname()) && !allowPrivateHTTP {
		return nil, ErrConfiguration
	}
	if now == nil {
		now = time.Now
	}
	base.Path = eventPath
	client := &http.Client{
		Timeout: 10 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	return &Sink{endpoint: base, secret: append([]byte(nil), secret...), client: client, now: now}, nil
}

func (sink *Sink) Deliver(ctx context.Context, workspaceKey string, event protocol.CanonicalEvent) error {
	if err := event.Validate(); err != nil {
		return ErrRejected
	}
	body, err := json.Marshal(event)
	if err != nil || len(body) > protocol.MaxBodyBytes {
		return ErrRejected
	}
	timestamp := strconv.FormatInt(sink.now().Unix(), 10)
	signature, err := protocol.Sign(sink.secret, timestamp, http.MethodPost, eventPath, body)
	if err != nil {
		return ErrConfiguration
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, sink.endpoint.String(), bytes.NewReader(body))
	if err != nil {
		return ErrConfiguration
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-NavishAI-Timestamp", timestamp)
	request.Header.Set("X-NavishAI-Signature", signature)
	request.Header.Set("X-NavishAI-Workspace-Key", workspaceKey)

	response, err := sink.client.Do(request)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	defer response.Body.Close()
	if _, err := io.Copy(io.Discard, io.LimitReader(response.Body, 64*1024)); err != nil {
		return fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	switch response.StatusCode {
	case http.StatusAccepted:
		return nil
	case http.StatusConflict:
		return ErrConflict
	case http.StatusBadRequest, http.StatusUnauthorized, http.StatusForbidden, http.StatusNotFound,
		http.StatusRequestEntityTooLarge, http.StatusUnsupportedMediaType, http.StatusUnprocessableEntity:
		return ErrRejected
	default:
		return fmt.Errorf("%w: HTTP %d", ErrUnavailable, response.StatusCode)
	}
}

func isLoopback(host string) bool {
	if host == "localhost" {
		return true
	}
	address := net.ParseIP(host)
	return address != nil && address.IsLoopback()
}
