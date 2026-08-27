class UsageRatesController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :require_rate_admin, only: %i[create rollback]

  rescue_from Current::RoleAccessDenied, with: :forbidden

  def show
    load_rates
  end

  def create
    UsageRateConfiguration.publish!(
      workspace: Current.require_workspace!, membership: Current.require_membership!,
      attributes: rate_params.to_h.symbolize_keys
    )
    redirect_to workspace_usage_rates_path(Current.workspace), notice: "Usage rate version published."
  rescue UsageRateConfiguration::InvalidConfiguration => error
    @rate_error = error.message
    @submitted_rates = rate_params.to_h
    load_rates
    render :show, status: :unprocessable_content
  end

  def rollback
    workspace = Current.require_workspace!
    setting = workspace.usage_rate_setting || raise(ActiveRecord::RecordNotFound)
    version = setting.versions.find(params[:version_id])
    UsageRateConfiguration.rollback!(
      workspace:, membership: Current.require_membership!, version:,
      expected_current_version_id: params[:expected_current_version_id]
    )
    redirect_to workspace_usage_rates_path(workspace), notice: "Usage rates rolled back for new ledgers."
  rescue UsageRateConfiguration::InvalidConfiguration => error
    @rate_error = error.message
    load_rates
    render :show, status: :unprocessable_content
  end

  private
    def require_rate_admin
      raise Current::RoleAccessDenied unless Current.require_membership!.can_configure_agents?
    end

    def load_rates
      @workspace = Current.require_workspace!
      @membership = Current.require_membership!
      @setting = @workspace.usage_rate_setting
      @versions = @setting ? @setting.versions.includes(:created_by_user).to_a : []
      @current_version = @setting&.current_version
      @can_configure = @membership.can_configure_agents?
    end

    def rate_params
      params.expect(usage_rate: [
        :expected_current_version_id, :currency, :source_name,
        :input_rate, :output_rate, :search_rate
      ])
    end

    def forbidden
      render "usage_rates/permission_denied", status: :forbidden
    end
end
