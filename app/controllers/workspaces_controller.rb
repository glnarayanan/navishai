class WorkspacesController < ApplicationController
  include WorkspaceAuthorization

  before_action :select_requested_workspace, only: :show

  def index
    @workspaces = Current.user.workspaces.order(:name)
  end

  def show
    @workspace = Current.require_workspace!
    @membership = Current.require_membership!
  end

  private
    def select_requested_workspace
      select_workspace(Current.user.workspaces.find(params[:id]))
    end
end
