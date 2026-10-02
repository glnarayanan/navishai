class SourcePurge
  def self.call(source:, membership: nil)
    source.corpus.with_lock do
      source.lock!
      if membership
        membership.lock!
        raise Current::RoleAccessDenied unless membership.workspace_id == source.workspace_id && membership.can_manage_work?
      else
        return if source.expires_at > Time.current
      end
      AuditEvent.record!(action: "source.deleted", source: membership ? :web : :job,
        workspace: source.workspace, actor: membership&.user, actor_kind: "system", subject: source)
      source.delete
    end
  end
end
