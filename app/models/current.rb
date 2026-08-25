class Current < ActiveSupport::CurrentAttributes
  class WorkspaceAccessDenied < StandardError; end
  class RoleAccessDenied < StandardError; end

  attribute :session, :user, :workspace

  def session=(session)
    super(session)
    self.user = session&.user
  end

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

  def require_membership!
    selected_workspace = require_workspace!
    Membership.find_by!(user: user, workspace: selected_workspace)
  end

  def require_role!(*roles)
    require_membership!.tap do |membership|
      raise RoleAccessDenied, "role cannot perform this action" unless roles.map(&:to_s).include?(membership.role)
    end
  end
end
