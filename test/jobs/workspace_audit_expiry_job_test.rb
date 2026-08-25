require "test_helper"

class WorkspaceAuditExpiryJobTest < ActiveJob::TestCase
  test "expires sensitive audit detail for one workspace and keeps ledger identity" do
    workspace = workspaces(:acme_support)
    other_workspace = workspaces(:beta_support)
    policy = workspace.create_workspace_data_policy!(audit_retention_days: 365)
    old_time = 2.years.ago
    event = AuditEvent.record!(
      action: "authentication.succeeded", source: :web, workspace:, actor: users(:owner),
      metadata: { method: "local" }, request_id: "private-request", ip_address: "192.0.2.1",
      occurred_at: old_time
    )
    other_event = AuditEvent.record!(
      action: "authentication.failed", source: :web, workspace: other_workspace,
      actor_kind: :anonymous, metadata: { method: "local" }, ip_address: "192.0.2.2",
      occurred_at: old_time
    )
    policy.update!(audit_expiry_status: "pending", audit_expiry_cutoff_at: 1.year.ago)

    WorkspaceAuditExpiryJob.perform_now(policy.id)

    event.reload
    assert_nil event.actor
    assert event.system?
    assert_empty event.metadata
    assert_nil event.request_id
    assert_nil event.ip_address
    assert event.expired_at
    assert_equal "authentication.succeeded", event.action
    assert_equal old_time.to_i, event.occurred_at.to_i
    assert_nil other_event.reload.expired_at
    assert_equal "completed", policy.reload.audit_expiry_status
    assert_equal 1, policy.audit_expired_event_count
    assert_equal "workspace.audit_expiry_completed", workspace.audit_events.order(:id).last.action
  end

  test "owner request is attributed and duplicate pending requests stay idempotent" do
    workspace = workspaces(:acme_support)
    policy = workspace.create_workspace_data_policy!(audit_retention_days: 365)

    assert_difference "AuditEvent.count", 1 do
      @policy = WorkspaceDataGovernance.request_audit_expiry!(
        workspace:, membership: memberships(:owner_support), source: :web
      )
    end
    assert_equal policy, @policy
    enqueued_count = enqueued_jobs.count
    assert_no_difference "AuditEvent.count" do
      WorkspaceDataGovernance.request_audit_expiry!(
        workspace:, membership: memberships(:owner_support), source: :web
      )
    end
    assert_equal enqueued_count, enqueued_jobs.count
    event = workspace.audit_events.order(:id).last
    assert_equal "workspace.audit_expiry_requested", event.action
    assert_equal users(:owner), event.actor
  end
end
