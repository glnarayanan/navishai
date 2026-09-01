class ProviderConnectionsController < ApplicationController
  include WorkspaceAuthorization

  SAFE_FORM_ERRORS = [
    "Choose a supported sign-in method.",
    "Enter the model this provider should use.",
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
    return head :not_found unless adapter_key.is_a?(String) && adapter_key.match?(ProviderConnectionProtocol::KEY_PATTERN)

    gateway = ProviderConnectionGateway.new
    provider = gateway.catalog(workspace_key: workspace.runner_key).find do |candidate|
      candidate.fetch("adapter_key") == adapter_key
    end
    return head :not_found unless provider&.fetch("configured")

    discovery = gateway.models(
      workspace_key: workspace.runner_key, adapter_key:, execution_mode: provider.fetch("execution_mode")
    )
    render json: discovery.slice("status", "checked_at", "models")
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

      validate_selection!(provider, attributes:)
      configured = gateway.configure(
        workspace_key: workspace.runner_key, request_id: SecureRandom.uuid, adapter_key:,
        auth_mode: attributes.fetch(:auth_mode), model: attributes.fetch(:model),
        execution_mode: selected_execution_mode(attributes),
        api_key: attributes.fetch(:api_key)
      )
      return unless record_confirmed_provider_change(
        workspace:, adapter_key:, action: "runtime.provider_configured"
      )
      return unless refresh_after_provider_change(workspace:, gateway:)

      if action_name == "create" && attributes.fetch(:auth_mode) == "api_key" &&
          attributes.fetch(:model).blank? && provider.fetch("model_required")
        redirect_to edit_workspace_provider_connection_path(workspace, adapter_key),
          notice: "#{configured.fetch("name")} key saved. Choose a model to continue."
        return
      end

      installation = current_installation_for(workspace:, provider: configured, adapter_key:)
      notice = if installation&.health_status == "available" && installation.compatibility_status != "incompatible"
        "#{configured.fetch("name")} settings were saved. Test the connection before allowing workspace access."
      else
        "#{configured.fetch("name")} settings were saved. No compatible runtime is available to test yet."
      end
      redirect_path = if installation
        workspace_runtime_installations_path(workspace, anchor: "runtime-#{installation.id}")
      else
        workspace_runtime_installations_path(workspace)
      end
      redirect_to redirect_path, notice:
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
      model = attributes.fetch(:model)
      unless provider.fetch("auth_modes").include?(auth_mode)
        raise RunnerClient::ConfigurationError, "Choose a supported sign-in method."
      end
      if provider.fetch("model_required") && model.blank? && !blank_model_allowed_for_initial_api_key?(provider, attributes)
        raise RunnerClient::ConfigurationError, "Enter the model this provider should use."
      end
      if auth_mode == "api_key" && attributes.fetch(:api_key).blank? && !provider.fetch("secret_configured")
        raise RunnerClient::ConfigurationError, "Enter an API key."
      end
    end

    def blank_model_allowed_for_initial_api_key?(provider, attributes)
      action_name == "create" && !provider.fetch("configured") && attributes.fetch(:auth_mode) == "api_key"
    end

    def provider_params
      @provider_params ||= params.expect(
        provider_connection: %i[ adapter_key auth_mode execution_mode model api_key ]
      ).to_h.symbolize_keys.reverse_merge(api_key: "", execution_mode: "")
    end

    def selected_execution_mode(attributes)
      return "bounded" if attributes.fetch(:auth_mode) == "api_key" && attributes[:execution_mode].blank?

      attributes.fetch(:execution_mode)
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
