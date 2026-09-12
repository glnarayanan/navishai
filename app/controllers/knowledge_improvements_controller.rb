class KnowledgeImprovementsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :set_context

  def show
    @queue = KnowledgeImprovementQueue.build(workspace: @workspace)
  end

  private
    def set_context
      @workspace = Current.require_workspace!
      @membership = Current.require_membership!
    end
end
