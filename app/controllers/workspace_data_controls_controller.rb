class WorkspaceDataControlsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action -> { require_role(:owner) }

  def show
    @policy = Current.workspace.workspace_data_policy || Current.workspace.create_workspace_data_policy!
    load_expiry_runs
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
    load_expiry_runs
    render :show, status: :unprocessable_content
  end

  def expire
    WorkspaceContentExpiry.request!(
      workspace: Current.workspace, membership: Current.require_membership!, source: :web
    )
    redirect_to workspace_data_controls_path(Current.workspace), notice: "Content expiry queued."
  rescue ArgumentError => error
    redirect_to workspace_data_controls_path(Current.workspace), alert: error.message
  end

  def expire_audit
    WorkspaceDataGovernance.request_audit_expiry!(
      workspace: Current.workspace, membership: Current.require_membership!, source: :web
    )
    redirect_to workspace_data_controls_path(Current.workspace), notice: "Audit expiry queued."
  rescue ArgumentError => error
    redirect_to workspace_data_controls_path(Current.workspace), alert: error.message
  end

  def export
    archive = WorkspacePortability.export(
      workspace: Current.workspace, membership: Current.require_membership!
    )
    send_data archive,
      filename: "navishai-workspace-#{Current.workspace.slug}-#{Date.current.iso8601}.json.gz",
      type: "application/gzip", disposition: "attachment"
  end

  def import
    upload = params[:workspace_archive]
    raise WorkspacePortability::InvalidArchive, "Choose a workspace archive." unless upload.respond_to?(:read)

    imported = WorkspacePortability.import(
      workspace: Current.workspace, membership: Current.require_membership!, archive_io: upload,
      name: params[:workspace_name], slug: params[:workspace_slug]
    )
    redirect_to workspace_data_controls_path(imported), notice: "Workspace imported."
  rescue WorkspacePortability::InvalidArchive => error
    @policy = Current.workspace.workspace_data_policy || Current.workspace.create_workspace_data_policy!
    @import_error = error.message
    load_expiry_runs
    render :show, status: :unprocessable_content
  end

  private
    def policy_params
      params.require(:workspace_data_policy).permit(:content_retention_days, :audit_retention_days)
        .to_h.transform_values(&:presence)
    end

    def load_expiry_runs
      @expiry_runs = Current.workspace.workspace_content_expiry_runs.order(created_at: :desc).limit(10)
    end
end
