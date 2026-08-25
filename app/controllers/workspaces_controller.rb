class WorkspacesController < ApplicationController
  include WorkspaceAuthorization

  before_action :select_requested_workspace, only: :show

  def index
    @workspaces = Current.user.workspaces.active.order(:name)
    @deleting_workspaces = Current.user.workspaces.where.not(deletion_requested_at: nil)
      .includes(:workspace_deletion_request, :organization, memberships: :user).order(:name)
  end

  def show
    redirect_to workspace_support_cases_path(Current.require_workspace!)
  end

  private
    def select_requested_workspace
      select_workspace(Current.user.workspaces.find(params[:id]))
    end
end
