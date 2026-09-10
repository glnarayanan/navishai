class RuntimeInstallationsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace

  def index
    load_installations
  end

  def detect
    return unless require_runtime_admin
    RuntimeRegistry.refresh!(
      workspace: Current.require_workspace!, membership: Current.require_membership!
    )
    redirect_to workspace_runtime_installations_path(Current.workspace), notice: "Provider check finished."
  rescue RunnerClient::Error, RuntimeRegistry::InvalidPolicy => error
    @runtime_error = user_facing_runtime_error(error, action: :refresh)
    load_installations
    render :index, status: :service_unavailable
  end

  def update
    return unless require_runtime_admin
    workspace = Current.require_workspace!
    installation = workspace.runtime_installations.find(params[:id])
    RuntimeRegistry.update_approval!(
      workspace:, membership: Current.require_membership!, installation:,
      attributes: installation_params.to_h.symbolize_keys
    )
    message = installation.reload.approved? ? "Provider access saved." : "Provider access removed."
    redirect_to workspace_runtime_installations_path(workspace, anchor: "runtime-#{installation.id}"), notice: message
  rescue RuntimeRegistry::InvalidPolicy => error
    @runtime_error = user_facing_runtime_error(error, action: :access)
    @editing_installation_id = params[:id].to_i
    load_installations
    render :index, status: :unprocessable_content
  end

  def test
    return unless require_runtime_admin
    workspace = Current.require_workspace!
    installation = workspace.runtime_installations.find(params[:id])
    RuntimeRegistry.test!(
      workspace:, membership: Current.require_membership!, installation:
    )
    installation.reload
    path = workspace_runtime_installations_path(workspace, anchor: "runtime-#{installation.id}")
    if installation.runtime_test_status == "passed"
      redirect_to path, notice: "Provider connection test passed."
    else
      redirect_to path, alert: "Provider connection test failed. Check the credentials and model, then try again."
    end
  rescue RunnerClient::Error, RuntimeRegistry::InvalidPolicy => error
    @runtime_error = user_facing_runtime_error(error, action: :test)
    load_installations
    render :index, status: :service_unavailable
  end

  private
    def require_runtime_admin
      return true if Current.require_membership!.can_configure_agents?

      head :forbidden
      false
    end

    def load_installations
      workspace = Current.require_workspace!
      @installations = workspace.runtime_installations.includes(:approved_by_user, personal_provider_account: { membership: :user }).ordered
      unless Current.require_membership!.can_configure_agents?
        @installations = @installations.select { |item| !item.personal_provider_account || item.personal_provider_account.membership_id == Current.require_membership!.id }
      end
      @can_configure = Current.require_membership!.can_configure_agents?
      load_provider_catalog(workspace)
    end

    def load_provider_catalog(workspace)
      return load_persisted_installations(include_missing: true) unless @can_configure

      @provider_catalog = ProviderConnectionGateway.new.catalog(workspace_key: workspace.runner_key)
      @configured_providers = @provider_catalog.select { |provider| provider.fetch("configured") }
      @current_installations = @configured_providers.each_with_object({}) do |provider, installations|
        installations[provider.fetch("adapter_key")] = current_installation_for(provider)
      end
      catalog_keys = @provider_catalog.map { |provider| provider.fetch("adapter_key") }
      @standalone_installations = @installations.reject do |installation|
        (!installation.personal_provider_account_id && catalog_keys.include?(installation.adapter_key)) || installation.health_status == "missing"
      end
    rescue RunnerClient::Error => error
      load_persisted_installations(include_missing: false)
      @provider_catalog_error = if error.is_a?(RunnerClient::ClientConfigurationError)
        "The provider service is not configured. Start the runner to manage provider connections."
      else
        "Live provider settings are unavailable. Showing the last known connection state."
      end
    end

    def load_persisted_installations(include_missing:)
      @provider_catalog = []
      @configured_providers = []
      @current_installations = {}
      @standalone_installations = include_missing ? @installations : @installations.reject { |installation| installation.health_status == "missing" }
      @provider_catalog_error = nil
    end

    def current_installation_for(provider)
      RuntimeInstallation.current_for_provider(
        @installations.select { |installation| !installation.personal_provider_account_id && installation.adapter_key == provider.fetch("adapter_key") },
        provider
      )
    end

    def installation_params
      params.expect(runtime_installation: [
        :approved, :max_timeout_seconds, :max_steps, :max_tool_calls, :max_input_units, :max_output_units,
        { allowed_role_keys: [], allowed_tools: [], allowed_data_classes: [], profile_keys: [] }
      ])
    end

    def user_facing_runtime_error(error, action:)
      return "The provider service is unavailable. Existing connections were not changed." if error.is_a?(RunnerClient::Unavailable)

      case action
      when :access
        "Workspace access could not be saved. Review the selected roles, actions, and customer data, then try again."
      when :test
        "The connection test could not be completed. Existing provider settings were not changed."
      else
        "Provider status could not be refreshed. Existing connections were not changed."
      end
    end
end
