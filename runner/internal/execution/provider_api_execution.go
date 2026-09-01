package execution

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/glnarayanan/navishai/runner/internal/adapters"
	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/providerapi"
	"github.com/glnarayanan/navishai/runner/internal/providerconfig"
	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
)

func (registry *Registry) executeProviderAPIRequest(ctx context.Context, request protocol.AdmissionRequest, connection providerconfig.Connection, emit func(protocol.CanonicalEvent) error) error {
	if registry == nil || registry.providerAPI == nil || registry.providers == nil || !boundedExecutionBoundary(request) ||
		connection.AuthMode != "api_key" ||
		!isDirectProviderAPIAdapter(request.Routing.AdapterKey) {
		return ErrPolicyDenied
	}
	adapter, ok := registry.config.Adapters[request.Routing.AdapterKey]
	if !ok || !providerAPIAdapterPolicyValid(request.Routing.AdapterKey, adapter) || !adapter.allows(request) ||
		len(request.Agent.AllowedTools) != 0 || request.Agent.MaxToolCalls != 0 {
		return ErrPolicyDenied
	}
	installation, ok := providerAPIInstallation(
		request.WorkspaceKey, request.Routing.AdapterKey, adapter, connection,
		registry.configurationIdentityKey, registry.currentTime(),
	)
	if !ok || installation.DetectionKey != request.Routing.DetectionKey ||
		installation.EffectiveModel != request.Routing.EffectiveModel ||
		installation.ConfigurationFingerprint != request.Routing.ConfigurationFingerprint ||
		installation.HealthStatus != "available" || installation.CompatibilityStatus != "compatible" {
		return ErrPolicyDenied
	}
	return registry.executeProviderAPI(ctx, request, adapter, connection, emit)
}

func (registry *Registry) executeProviderAPI(ctx context.Context, request protocol.AdmissionRequest, adapter AdapterConfig, connection providerconfig.Connection, emit func(protocol.CanonicalEvent) error) error {
	prompt, err := executionPrompt(request)
	if err != nil {
		return ErrPolicyDenied
	}
	if ctx == nil {
		ctx = context.Background()
	}
	runContext, cancel := context.WithTimeout(ctx, time.Duration(request.Agent.TimeoutSeconds)*time.Second)
	defer cancel()
	sequence := 2
	emitEvent := func(eventType string, data map[string]any) error {
		event, eventErr := protocol.NewCanonicalEvent(request.RunID, sequence, eventType, registry.currentTime(), data)
		if eventErr != nil {
			return eventErr
		}
		if eventErr := emit(event); eventErr != nil {
			return fmt.Errorf("emit provider API event: %w", eventErr)
		}
		sequence++
		return nil
	}
	if err := emitEvent("run.started", map[string]any{
		"adapter": request.Routing.AdapterKey, "scenario": "api_key", "attempt": request.Task.Attempt,
	}); err != nil {
		return err
	}
	outputTokens := request.Routing.MaxOutputUnits
	if outputTokens > providerapi.MaxOutputTokens {
		outputTokens = providerapi.MaxOutputTokens
	}
	result, generateErr := registry.providerAPI.Generate(
		runContext, request.Routing.AdapterKey, connection.APIKey, connection.Model, prompt, outputTokens,
	)
	if generateErr != nil {
		eventType, data := providerAPIErrorEvent(generateErr, runContext)
		if eventErr := emitEvent(eventType, data); eventErr != nil {
			return eventErr
		}
		return nil
	}
	if !validProviderAPIOutput(result.Text) {
		if err := emitEvent("run.failed", map[string]any{"code": "provider_api_failed", "retryable": false}); err != nil {
			return err
		}
		return nil
	}
	if !adapters.WithinUnitBudget(request, result.InputTokens, result.OutputTokens) {
		if err := emitEvent("run.failed", map[string]any{"code": "runtime_unit_budget_exceeded", "retryable": false}); err != nil {
			return err
		}
		return nil
	}
	if err := emitEvent("output.produced", map[string]any{"text": result.Text}); err != nil {
		return err
	}
	if err := emitEvent("usage.observed", map[string]any{"input_units": result.InputTokens, "output_units": result.OutputTokens}); err != nil {
		return err
	}
	if err := emitEvent("run.completed", map[string]any{"outcome": "completed"}); err != nil {
		return err
	}
	return nil
}

func providerAPIErrorEvent(err error, ctx context.Context) (string, map[string]any) {
	var providerErr *providerapi.Error
	if errors.As(err, &providerErr) {
		switch providerErr.Code {
		case providerapi.CodeCanceled:
			return "run.canceled", map[string]any{"reason": "Provider request was canceled."}
		case providerapi.CodeTimeout:
			return "run.timed_out", map[string]any{"reason": "Provider request exceeded the run deadline."}
		case providerapi.CodeUnavailable:
			return "run.failed", map[string]any{"code": "provider_api_failed", "retryable": true}
		}
	}
	if errors.Is(err, context.Canceled) || (ctx != nil && errors.Is(ctx.Err(), context.Canceled)) {
		return "run.canceled", map[string]any{"reason": "Provider request was canceled."}
	}
	if errors.Is(err, context.DeadlineExceeded) || (ctx != nil && errors.Is(ctx.Err(), context.DeadlineExceeded)) {
		return "run.timed_out", map[string]any{"reason": "Provider request exceeded the run deadline."}
	}
	return "run.failed", map[string]any{"code": "provider_api_failed", "retryable": false}
}

func validProviderAPIOutput(value string) bool {
	if value == "" || len(value) > 100*1024 || !utf8.ValidString(value) || strings.TrimSpace(value) == "" {
		return false
	}
	for _, character := range value {
		if !unicode.IsControl(character) || character == '\n' || character == '\r' || character == '\t' {
			continue
		}
		return false
	}
	return true
}

func (registry *Registry) currentTime() time.Time {
	if registry != nil && registry.now != nil {
		return registry.now()
	}
	return time.Now()
}

var _ runtimecatalog.RuntimeTester = (*Registry)(nil)
