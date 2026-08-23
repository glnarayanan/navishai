class IdentityMatchReview
  def self.resolve!(workspace:, source_identity:, target:, membership:)
    SourceIdentity.transaction do
      reviewer = workspace.memberships.lock.find(membership.id)
      raise Current::RoleAccessDenied unless reviewer.can_manage_work?

      identity = workspace.source_identities.lock.find(source_identity.id)
      raise ActiveRecord::RecordInvalid, identity unless identity.ambiguous?

      scoped_target = identity.account? ? workspace.accounts.find(target.id) : workspace.contacts.find(target.id)
      canonical_target = scoped_target.canonical
      candidate_roots = identity.identity_match_candidates.map { |candidate| candidate.record.canonical }
      raise ArgumentError, "target is not a recorded candidate" unless candidate_roots.include?(canonical_target)

      target_attribute = identity.account? ? { account: canonical_target } : { contact: canonical_target }
      identity.update!(target_attribute.merge(
        status: :matched,
        resolution_method: :reviewed,
        resolved_by: reviewer.user,
        resolved_at: Time.current
      ))
      AuditEvent.record!(
        action: "source_identity.reviewed",
        source: :web,
        workspace: workspace,
        actor: reviewer.user,
        subject: identity,
        metadata: { entity_kind: identity.entity_kind, resolution_method: "reviewed" }
      )
      canonical_target
    end
  end
end
