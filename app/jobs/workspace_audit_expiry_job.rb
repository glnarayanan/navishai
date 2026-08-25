class WorkspaceAuditExpiryJob < ApplicationJob
  queue_as :background

  def self.enqueue_after_commit(policy)
    ActiveRecord.after_all_transactions_commit { perform_later(policy.id) }
  rescue ActiveJob::EnqueueError
    Rails.logger.error("Workspace audit expiry enqueue failed for policy #{policy.id}")
  end

  def perform(policy_id)
    policy = WorkspaceDataPolicy.find(policy_id)
    connection = ActiveRecord::Base.connection
    connection.execute("SELECT pg_advisory_lock(49, #{connection.quote(policy.workspace_id)})")
    policy.with_lock do
      return if policy.audit_expiry_status == "completed"
      policy.update!(audit_expiry_status: "running", audit_expiry_started_at: Time.current)
    end
    count = connection.select_value(
      "SELECT expire_workspace_audit(#{connection.quote(policy.workspace_id)}, #{connection.quote(policy.audit_expiry_cutoff_at)})"
    ).to_i
    policy.with_lock do
      policy.update!(
        audit_expiry_status: "completed", audit_expired_event_count: count,
        audit_expiry_failure_code: nil, audit_expiry_completed_at: Time.current
      )
      AuditEvent.record!(
        action: "workspace.audit_expiry_completed", source: :job, workspace: policy.workspace,
        actor_kind: :system, subject: policy, metadata: { event_count: count }
      )
    end
  rescue StandardError => error
    fail_policy!(policy, error) if policy
  ensure
    connection&.execute("SELECT pg_advisory_unlock(49, #{connection.quote(policy.workspace_id)})") if policy
  end

  private
    def fail_policy!(policy, error)
      code = error.class.name.demodulize.underscore.gsub(/[^a-z0-9_]/, "_").first(100)
      code = "expiry_error" unless code.match?(/\A[a-z]/)
      policy.with_lock do
        policy.update!(
          audit_expiry_status: "failed", audit_expiry_failure_code: code,
          audit_expiry_completed_at: Time.current
        )
        AuditEvent.record!(
          action: "workspace.audit_expiry_failed", source: :job, workspace: policy.workspace,
          actor_kind: :system, subject: policy, metadata: { failure_code: code }
        )
      end
      Rails.logger.error("Workspace audit expiry for policy #{policy.id} failed: #{error.class}")
    end
end
