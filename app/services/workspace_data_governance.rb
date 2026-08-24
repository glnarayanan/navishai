class WorkspaceDataGovernance
  AUDIT_EXPIRY_STALE_AFTER = 1.hour

  def self.update_policy!(workspace:, membership:, attributes:, occurred_at: Time.current)
    WorkspaceDataPolicy.transaction do
      actor = workspace.memberships.lock.find(membership.id)
      raise Current::RoleAccessDenied unless actor.owner?

      policy = workspace.workspace_data_policy || workspace.create_workspace_data_policy!
      policy.lock!
      policy.update!(attributes)
      AuditEvent.record!(
        action: "workspace.data_policy_updated", source: :web, workspace:, actor: actor.user,
        subject: policy,
        metadata: {
          content_retention_days: policy.content_retention_days || 0,
          audit_retention_days: policy.audit_retention_days || 0
        },
        occurred_at:
      )
      policy
    end
  end

  def self.request_audit_expiry!(workspace:, membership: nil, source: :job, requested_at: Time.current)
    policy, enqueue = WorkspaceDataPolicy.transaction do
      policy = workspace.workspace_data_policy.lock!
      cutoff = policy.audit_cutoff(at: requested_at)
      raise ArgumentError, "audit retention is not enabled" unless cutoff

      actor = nil
      if membership
        actor = workspace.memberships.lock.find(membership.id)
        raise Current::RoleAccessDenied unless actor.owner?
      end
      if policy.audit_expiry_status == "running" && policy.audit_expiry_started_at < requested_at - AUDIT_EXPIRY_STALE_AFTER
        policy.update!(audit_expiry_status: "failed", audit_expiry_failure_code: "interrupted", audit_expiry_completed_at: requested_at)
      end
      next [ policy, false ] if policy.audit_expiry_status.in?(%w[pending running])

      policy.update!(
        audit_expiry_status: "pending", audit_expiry_cutoff_at: cutoff, audit_expired_event_count: 0,
        audit_expiry_failure_code: nil, audit_expiry_started_at: nil, audit_expiry_completed_at: nil
      )
      AuditEvent.record!(
        action: "workspace.audit_expiry_requested", source:, workspace:, actor: actor&.user,
        actor_kind: actor ? nil : :system, subject: policy, metadata: {}, occurred_at: requested_at
      )
      [ policy, true ]
    end
    WorkspaceAuditExpiryJob.enqueue_after_commit(policy) if enqueue
    policy
  end
end
