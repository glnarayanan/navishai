class ProviderConnectionsController < ApplicationController
  include WorkspaceAuthorization

  SAFE_FORM_ERRORS = [
    "Choose a supported sign-in method.",
    "Choose a supported execution boundary.",
    "Enter an API key."
  ].freeze

  before_action :require_workspace
  before_action :require_provider_admin
  before_action :prevent_credential_caching

  def new
    load_new_catalog
    @provider = selected_provider || @provider_catalog.first
  rescue RunnerClient::Error => error
    redirect_to workspace_runtime_installations_path(Current.workspace), alert: user_facing_error(error)
  end

  def create
    configure_provider
  end

  def edit
    load_catalog
    @provider = @provider_catalog.find { |provider| provider.fetch("adapter_key") == params[:adapter_key] }
    raise ActiveRecord::RecordNotFound unless @provider&.fetch("configured")
  rescue RunnerClient::Error => error
    redirect_to workspace_runtime_installations_path(Current.workspace), alert: user_facing_error(error)
  end

  def update
    configure_provider(adapter_key: params[:adapter_key])
  end

  def destroy
    workspace = Current.require_workspace!
    gateway = ProviderConnectionGateway.new
    provider = gateway.remove(
      workspace_key: workspace.runner_key, request_id: SecureRandom.uuid, adapter_key: params[:adapter_key]
    )
    return unless record_confirmed_provider_change(
      workspace:, adapter_key: params[:adapter_key], action: "runtime.provider_removed"
    )
    return unless refresh_after_provider_change(workspace:, gateway:)

    redirect_to workspace_runtime_installations_path(workspace), notice: "#{provider.fetch("name")} was removed."
  rescue RunnerClient::Error, RuntimeRegistry::InvalidPolicy => error
    redirect_to workspace_runtime_installations_path(Current.workspace), alert: user_facing_error(error)
  end

  def models
    workspace = Current.require_workspace!
    adapter_key = params[:adapter_key]
    execution_mode = params[:execution_mode]
    return head :not_found unless adapter_key.is_a?(String) && adapter_key.match?(ProviderConnectionProtocol::KEY_PATTERN) &&
      execution_mode.is_a?(String) && RuntimeInstallation::KNOWN_EXECUTION_MODES.include?(execution_mode)

    gateway = ProviderConnectionGateway.new
    provider = gateway.catalog(workspace_key: workspace.runner_key).find do |candidate|
      candidate.fetch("adapter_key") == adapter_key
    end
    return head :not_found unless provider&.fetch("configured")
    return render json: { status: "failed", models: [] }, status: :conflict unless
      provider.fetch("execution_mode") == execution_mode

    discovery = gateway.models(
      workspace_key: workspace.runner_key, adapter_key:, execution_mode:
    )
    render json: discovery.slice("status", "checked_at", "models")
  rescue RunnerClient::Conflict
    render json: { status: "failed", models: [] }, status: :conflict
  rescue RunnerClient::Unavailable
    render json: { status: "unavailable", models: [] }, status: :service_unavailable
  rescue RunnerClient::MalformedResponse
    render json: { status: "failed", models: [] }, status: :bad_gateway
  rescue RunnerClient::Error
    render json: { status: "failed", models: [] }, status: :bad_gateway
  end

  private
    def configure_provider(adapter_key: nil)
      workspace = Current.require_workspace!
      attributes = provider_params
      adapter_key ||= attributes.fetch(:adapter_key)
      gateway = ProviderConnectionGateway.new
      catalog = gateway.catalog(workspace_key: workspace.runner_key)
      provider = catalog.find { |candidate| candidate.fetch("adapter_key") == adapter_key }
      raise ActiveRecord::RecordNotFound unless provider

      attributes = attributes.merge(execution_mode: selected_execution_mode(attributes, provider:))
      validate_selection!(provider, attributes:)
      configured = gateway.configure(
        workspace_key: workspace.runner_key, request_id: SecureRandom.uuid, adapter_key:,
        auth_mode: attributes.fetch(:auth_mode), model: attributes.fetch(:model),
        execution_mode: attributes.fetch(:execution_mode),
        api_key: attributes.fetch(:api_key)
      )
      return unless record_confirmed_provider_change(
        workspace:, adapter_key:, action: "runtime.provider_configured"
      )
      return unless refresh_after_provider_change(workspace:, gateway:)

      if incomplete_model_configuration?(configured)
        notice = if provider_test_requested?
          "#{configured.fetch("name")} settings were saved. The connection test was not run: #{test_block_reason(provider: configured, installation: nil)}."
        else
          "#{configured.fetch("name")} settings were saved. Choose a model to continue."
        end
        redirect_to edit_workspace_provider_connection_path(workspace, adapter_key),
          notice: notice
        return
      end

      installation = current_installation_for(workspace:, provider: configured, adapter_key:)
      if provider_test_requested?
        return save_and_test_provider(workspace:, gateway:, provider: configured, installation:)
      end

      redirect_to provider_status_path(workspace:, installation:), notice: saved_provider_notice(configured, installation:)
    rescue RunnerClient::Error, RuntimeRegistry::InvalidPolicy => error
      render_configuration_error(error, adapter_key:)
    rescue ProviderConnectionProtocol::MalformedMessage => error
      render_configuration_error(RunnerClient::ConfigurationError.new(error.message), adapter_key:)
    end

    def render_configuration_error(error, adapter_key:)
      @provider_form_error = user_facing_error(error)
      action_name == "update" ? load_catalog : load_new_catalog
      @provider = @provider_catalog.find { |candidate| candidate.fetch("adapter_key") == adapter_key } || selected_provider || @provider_catalog.first
      @submitted_auth_mode = provider_params[:auth_mode]
      @submitted_model = provider_params[:model]
      @submitted_execution_mode = provider_params[:execution_mode]
      render action_name == "update" ? :edit : :new, status: :unprocessable_content
    rescue RunnerClient::Error
      redirect_to workspace_runtime_installations_path(Current.workspace), alert: @provider_form_error
    end

    def refresh_runtime_installations(workspace:, gateway:)
      RuntimeRegistry.refresh!(
        workspace:, membership: Current.require_membership!, client: gateway
      )
    end

    def record_provider_change!(workspace:, adapter_key:, action:)
      RuntimeInstallation.transaction do
        RuntimeRegistry.invalidate_adapter!(
          workspace:, membership: Current.require_membership!, adapter_key:
        )
        audit_event(action, workspace:, subject: workspace)
      end
    end

    def record_confirmed_provider_change(workspace:, adapter_key:, action:)
      record_provider_change!(workspace:, adapter_key:, action:)
      true
    rescue RuntimeRegistry::InvalidPolicy, ActiveRecord::ActiveRecordError
      redirect_to workspace_runtime_installations_path(workspace), alert: confirmed_change_failure_message
      false
    end

    def refresh_after_provider_change(workspace:, gateway:)
      refresh_runtime_installations(workspace:, gateway:)
      true
    rescue RunnerClient::Error, RuntimeRegistry::InvalidPolicy, ActiveRecord::ActiveRecordError
      redirect_to workspace_runtime_installations_path(workspace),
        alert: confirmed_change_failure_message
      false
    end

    def confirmed_change_failure_message
      "The provider change was confirmed and saved, but local status could not be refreshed. Refresh status again."
    end

    def load_catalog
      @provider_catalog = ProviderConnectionGateway.new.catalog(workspace_key: Current.require_workspace!.runner_key)
    end

    def load_new_catalog
      load_catalog
      @all_providers_configured = @provider_catalog.present? && @provider_catalog.all? { |provider| provider.fetch("configured") }
      @provider_catalog = @provider_catalog.reject { |provider| provider.fetch("configured") }
    end

    def current_installation_for(workspace:, provider:, adapter_key:)
      candidates = workspace.runtime_installations.where(adapter_key:).to_a
      return if candidates.empty?

      model = provider.fetch("model").presence
      version = provider.fetch("executable_version").presence
      execution_mode = provider.fetch("execution_mode").presence
      return if model.blank? && version.blank? || execution_mode.blank?

      candidates = candidates.select { |installation| installation.effective_model == model } if model
      candidates = candidates.select { |installation| installation.executable_version == version } if version
      candidates = candidates.select { |installation| installation.execution_mode == execution_mode }
      return if candidates.empty?

      built_in = candidates.select { |installation| installation.transport == "built_in_https" }
      candidates = if provider.fetch("auth_mode") == "api_key"
        built_in
      else
        candidates - built_in
      end
      return if candidates.empty?

      candidates = candidates.reject { |installation| installation.health_status == "missing" }
      return if candidates.empty?

      healthy = candidates.select do |installation|
        installation.health_status == "available" && installation.compatibility_status != "incompatible"
      end
      candidates = healthy if healthy.any?

      candidates.max_by { |installation| [ installation.checked_at.to_i, installation.id ] }
    end

    def selected_provider
      adapter_key = params.dig(:provider_connection, :adapter_key).presence || params[:adapter_key].presence
      @provider_catalog.find { |provider| provider.fetch("adapter_key") == adapter_key }
    end

    def validate_selection!(provider, attributes:)
      auth_mode = attributes.fetch(:auth_mode)
      execution_mode = attributes.fetch(:execution_mode)
      unless provider.fetch("auth_modes").include?(auth_mode)
        raise RunnerClient::ConfigurationError, "Choose a supported sign-in method."
      end
      unless provider.fetch("supported_execution_modes").include?(execution_mode)
        raise RunnerClient::ConfigurationError, "Choose a supported execution boundary."
      end
      if auth_mode == "api_key" && execution_mode != "bounded"
        raise RunnerClient::ConfigurationError, "Choose a supported execution boundary."
      end
      if auth_mode == "subscription" && !execution_mode.in?(%w[host_trusted strong_isolated])
        raise RunnerClient::ConfigurationError, "Choose a supported execution boundary."
      end
      if auth_mode == "api_key" && attributes.fetch(:api_key).blank? && !provider.fetch("secret_configured")
        raise RunnerClient::ConfigurationError, "Enter an API key."
      end
    end

    def incomplete_model_configuration?(provider)
      provider.fetch("configured") && model_required_for_runtime?(provider) && provider.fetch("model").blank?
    end

    def provider_test_requested?
      params[:commit].to_s == "Save and test"
    end

    def save_and_test_provider(workspace:, gateway:, provider:, installation:)
      unless testable_installation?(provider:, installation:)
        redirect_to provider_status_path(workspace:, installation:),
          notice: "#{provider.fetch("name")} settings were saved. The connection test was not run: #{test_block_reason(provider:, installation:)}."
        return
      end

      RuntimeRegistry.test!(
        workspace:, membership: Current.require_membership!, installation:, client: gateway
      )
      installation.reload
      if installation.runtime_test_status == "passed"
        redirect_to provider_status_path(workspace:, installation:),
          notice: "#{provider.fetch("name")} settings were saved and the connection test passed."
      else
        redirect_to provider_status_path(workspace:, installation:),
          alert: "#{provider.fetch("name")} settings were saved, but the connection test failed. Check the credentials and model, then try again."
      end
    rescue RunnerClient::Error, RuntimeRegistry::InvalidPolicy
      redirect_to provider_status_path(workspace:, installation:),
        alert: "#{provider.fetch("name")} settings were saved. Prior approval and test evidence were cleared; the new connection test failed. Workspace access remains disabled until a successful test is recorded."
    end

    def saved_provider_notice(provider, installation:)
      if testable_installation?(provider:, installation:)
        "#{provider.fetch("name")} settings were saved. Test the connection before allowing workspace access."
      else
        "#{provider.fetch("name")} settings were saved. The connection test is not ready: #{test_block_reason(provider:, installation:)}."
      end
    end

    def testable_installation?(provider:, installation:)
      return false unless installation
      return false unless provider.fetch("available") && provider.fetch("health_status") == "available"
      return false unless installation.health_status == "available" && installation.compatibility_status != "incompatible"
      return false unless installation.transport.in?(RuntimeInstallation::KNOWN_TRANSPORTS) &&
        installation.execution_mode.in?(RuntimeInstallation::KNOWN_EXECUTION_MODES)
      return false unless installation.effective_model.present? &&
        installation.configuration_fingerprint.match?(RuntimeInstallation::FINGERPRINT_FORMAT)
      return false if provider.fetch("model").present? && installation.effective_model != provider.fetch("model")
      return false if provider.fetch("executable_version").present? &&
        installation.executable_version != provider.fetch("executable_version")

      installation.execution_mode == provider.fetch("execution_mode") &&
        (provider.fetch("auth_mode") == "api_key" ? installation.transport == "built_in_https" : installation.transport != "built_in_https")
    end

    def test_block_reason(provider:, installation:)
      return "choose a model in Edit settings first" if model_required_for_runtime?(provider) && provider.fetch("model").blank?
      return "the runner does not currently report a compatible runtime for this provider" unless installation
      return "the runner does not currently report this provider as available" unless provider.fetch("available") && provider.fetch("health_status") == "available"
      return "the detected runtime is not healthy or compatible" unless installation.health_status == "available" && installation.compatibility_status != "incompatible"
      return "the detected runtime identity is not current" unless installation.execution_mode == provider.fetch("execution_mode")
      return "the selected model is not current on the detected runtime" if provider.fetch("model").present? && installation.effective_model != provider.fetch("model")
      return "the detected runtime version is not current" if provider.fetch("executable_version").present? && installation.executable_version != provider.fetch("executable_version")

      "the current runtime is not ready for a connection test"
    end

    def model_required_for_runtime?(provider)
      provider.fetch("model_required") || provider.fetch("auth_mode") == "api_key"
    end

    def provider_status_path(workspace:, installation:)
      return workspace_runtime_installations_path(workspace) unless installation

      workspace_runtime_installations_path(workspace, anchor: "runtime-#{installation.id}")
    end

    def provider_params
      @provider_params ||= params.expect(
        provider_connection: %i[ adapter_key auth_mode execution_mode model api_key ]
      ).to_h.symbolize_keys.reverse_merge(api_key: "", execution_mode: "")
    end

    def selected_execution_mode(attributes, provider:)
      if attributes.fetch(:auth_mode) == "api_key"
        return "bounded" if provider.fetch("supported_execution_modes").include?("bounded")

        return ""
      end

      attributes.fetch(:execution_mode).to_s
    end

    def require_provider_admin
      return if Current.require_membership!.can_configure_agents?

      head :forbidden
    end

    def prevent_credential_caching
      response.headers["Cache-Control"] = "no-store"
      response.headers["Pragma"] = "no-cache"
    end

    def user_facing_error(error)
      return error.message if SAFE_FORM_ERRORS.include?(error.message)

      case error
      when RunnerClient::Unavailable
        "The provider service is unavailable. Your existing connections were not changed."
      when RunnerClient::AmbiguousResult
        "The provider service did not confirm the change. Check connection status before trying again."
      when RunnerClient::AuthenticationError, RunnerClient::PolicyDenied
        "This provider change was refused. Check your workspace access and try again."
      when RunnerClient::ClientConfigurationError
        "The provider service is not configured. Start the runner, then try again."
      when RunnerClient::ConfigurationError, RunnerClient::Conflict
        "Check the provider, sign-in method, model, and credentials, then try again."
      else
        "The provider change could not be completed. No credentials were saved in the web app."
      end
    end
end
