class WorkspaceDataGovernance
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
end
