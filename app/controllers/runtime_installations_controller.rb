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
    @runtime_error = error.message
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
    @runtime_error = error.message
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
    message = if installation.runtime_test_status == "passed"
      "Provider connection test passed."
    else
      "Provider connection test failed: #{installation.runtime_test_failure_code}."
    end
    redirect_to workspace_runtime_installations_path(workspace, anchor: "runtime-#{installation.id}"), notice: message
  rescue RunnerClient::Error, RuntimeRegistry::InvalidPolicy => error
    @runtime_error = error.message
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
      @installations = workspace.runtime_installations.includes(:approved_by_user).ordered
      @can_configure = Current.require_membership!.can_configure_agents?
    end

    def installation_params
      params.expect(runtime_installation: [
        :approved, :max_timeout_seconds, :max_steps, :max_tool_calls, :max_input_units, :max_output_units,
        { allowed_role_keys: [], allowed_tools: [], allowed_data_classes: [], profile_keys: [] }
      ])
    end
end
