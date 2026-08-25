class WorkspaceDataControlsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action -> { require_role(:owner) }

  def show
    @policy = Current.workspace.workspace_data_policy || Current.workspace.create_workspace_data_policy!
  end

  def update
    WorkspaceDataGovernance.update_policy!(
      workspace: Current.workspace,
      membership: Current.require_membership!,
      attributes: policy_params
    )
    redirect_to workspace_data_controls_path(Current.workspace), notice: "Data retention policy saved."
  rescue ActiveRecord::RecordInvalid => error
    @policy = error.record
    render :show, status: :unprocessable_content
  end

  private
    def policy_params
      params.require(:workspace_data_policy).permit(:content_retention_days, :audit_retention_days)
        .to_h.transform_values(&:presence)
    end
end
