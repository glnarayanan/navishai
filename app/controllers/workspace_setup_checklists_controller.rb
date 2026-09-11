class WorkspaceSetupChecklistsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action -> { require_role(:owner, :admin) }

  def show
    @workspace = Current.require_workspace!
    @items = WorkspaceSetupChecklist.new(@workspace).items
  end
end
