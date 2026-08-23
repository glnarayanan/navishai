class Current < ActiveSupport::CurrentAttributes
  class WorkspaceAccessDenied < StandardError; end

  attribute :user, :workspace

  def user=(user)
    super
    self.workspace = nil unless user && workspace && Membership.exists?(user: user, workspace: workspace)
  end

  def workspace=(workspace)
    if workspace && (!user || !Membership.exists?(user: user, workspace: workspace))
      raise WorkspaceAccessDenied, "user cannot access workspace"
    end

    super
  end

  def require_workspace!
    workspace || raise(WorkspaceAccessDenied, "no active workspace")
  end
end
