class WorkspaceDeletionsController < ApplicationController
  def create
    workspace = Current.user.workspaces.active.find(params[:workspace_id])
    WorkspaceDeletion.request!(
      workspace:, membership: workspace.memberships.find_by!(user: Current.user),
      confirmation: params[:confirmation]
    )
    cookies.delete(:workspace_id)
    redirect_to workspaces_path, notice: "Workspace deletion queued. Access is now blocked."
  rescue Current::RoleAccessDenied
    head :forbidden
  rescue ArgumentError => error
    redirect_to workspace_data_controls_path(params[:workspace_id]), alert: error.message
  end

  def update
    workspace = Current.user.workspaces.where.not(deletion_requested_at: nil).find(params[:workspace_id])
    WorkspaceDeletion.retry!(workspace:, membership: workspace.memberships.find_by!(user: Current.user))
    redirect_to workspaces_path, notice: "Workspace deletion queued again."
  rescue Current::RoleAccessDenied
    head :forbidden
  rescue ArgumentError => error
    redirect_to workspaces_path, alert: error.message
  end
end
