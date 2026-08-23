class Current < ActiveSupport::CurrentAttributes
  class WorkspaceAccessDenied < StandardError; end

  attribute :user, :workspace

  def user=(user)
    self.workspace = nil if self.user != user
    super(user)
  end

  def workspace=(workspace)
    super(nil)

    if workspace && (!user || !Membership.exists?(user: user, workspace: workspace))
      raise WorkspaceAccessDenied, "user cannot access workspace"
    end

    super(workspace)
  end

  def require_workspace!
    selected_workspace = workspace || raise(WorkspaceAccessDenied, "no active workspace")
    return selected_workspace if user && Membership.exists?(user: user, workspace: selected_workspace)

    self.workspace = nil
    raise WorkspaceAccessDenied, "user cannot access workspace"
  end
end
