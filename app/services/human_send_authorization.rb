class HumanSendAuthorization
  def self.with_current_authority(workspace:, membership:)
    Workspace.transaction do
      current_workspace = Workspace.lock.find(workspace.id)
      raise ActiveRecord::RecordNotFound if current_workspace.deletion_requested?

      session = Session.active.lock.find(Current.session&.id)
      actor = current_workspace.memberships.lock.find(membership.id)
      raise Current::RoleAccessDenied unless actor.can_write? && actor.user == session.user

      yield actor
    end
  end
end
